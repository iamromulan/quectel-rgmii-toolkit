#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# tailscale.sh — CGI Endpoint: Tailscale VPN Management (GET + POST)
# =============================================================================
# GET:  Returns installation status, daemon state, connection info, and peers.
# POST: Connect/disconnect, start/stop daemon, enable/disable on boot, logout.
#
# Tailscale manages its own config in /etc/tailscale/ — we are a thin
# control layer, not a service owner. No UCI config needed.
#
# Data sources:
#   tailscale status --json   -> connection state, self info, peers, DNS
#   tailscale version         -> installed version
#   /etc/init.d/tailscale     -> daemon control (start/stop/enable/disable)
#
# POST body: { "action": "connect"|"disconnect"|"logout"|"start_service"|
#                         "stop_service"|"set_boot_enabled"|"set_exit_node"|
#                         "set_ssh"|"install"|"install_status"|"uninstall"|
#                         "check_update"|"update"|"set_net_fixes" }
#
# Install / update logic lives in /usr/lib/qmanager/tailscale_mgr.sh and the
# reachability fixes (fw4 zone + pref-1990 ip rule) in tailscale_net.sh; this
# CGI only validates, dispatches and orphans the background workers. Two
# install sources: official (QManager owns init + fixes) and tiny (the opkg
# package owns both; ts_net_owned gates every fix).
#
# Endpoint: GET/POST /cgi-bin/quecmanager/vpn/tailscale.sh
# Install location: /www/cgi-bin/quecmanager/vpn/tailscale.sh
# =============================================================================

qlog_init "cgi_tailscale"
cgi_headers
cgi_handle_options

AUTH_URL_FILE="/tmp/qmanager_tailscale_auth_url"
# B4.1: tailscale up output lives in the root-only run dir (jq reads it back)
TS_UP_OUTPUT="/var/run/qmanager/tailscale_up_output"
TS_UP_PID_FILE="/tmp/qmanager_tailscale_up_pid"
# Live install/update log (worker stdout+stderr), root-only run dir.
TS_INSTALL_LOG="/var/run/qmanager/tailscale_install.log"
TS_INSTALL_RESULT="/tmp/qmanager_tailscale_install.json"
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh
# Install/update pipeline + reachability (zone + pref-1990 rule). Guarded: a
# dot-source of a missing file aborts the whole CGI under ash.
[ -f /usr/lib/qmanager/tailscale_net.sh ] && . /usr/lib/qmanager/tailscale_net.sh
[ -f /usr/lib/qmanager/tailscale_mgr.sh ] && . /usr/lib/qmanager/tailscale_mgr.sh

# The test knobs are shell-only; a request can never set them.
unset TS_TEST_FAIL_HEALTH TS_TEST_FORCE_UPDATE

if ! command -v ts_variant >/dev/null 2>&1 || ! command -v ts_net_enabled >/dev/null 2>&1; then
    cgi_error "library_missing" "Tailscale support library is missing"
    exit 0
fi

# --- Helper: check if tailscale + tailscaled are installed -------------------
is_installed() {
    command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1
}

# --- Helper: check if tailscaled daemon is running ---------------------------
is_daemon_running() {
    if [ -x /etc/init.d/tailscale ]; then
        /etc/init.d/tailscale running >/dev/null 2>&1
    else
        pidof tailscaled >/dev/null 2>&1
    fi
}

# --- Helper: check if tailscale is enabled on boot --------------------------
# luci-app-tailscale-community-tiny stores its enabled flag at
# tailscale.settings.service_enabled (see /etc/config/tailscale shipped
# by the package). Fall back to the init.d enabled check if the UCI
# section is absent for any reason.
get_boot_enabled() {
    local uci_enabled
    uci_enabled=$(uci -q get tailscale.settings.service_enabled 2>/dev/null)
    if [ -n "$uci_enabled" ]; then
        [ "$uci_enabled" = "1" ] && echo "true" || echo "false"
        return
    fi
    if [ -x /etc/init.d/tailscale ]; then
        /etc/init.d/tailscale enabled && echo "true" || echo "false"
    else
        echo "false"
    fi
}

# --- Helper: kill stale tailscale up process from previous connect attempt ---
kill_stale_ts_up() {
    if [ -f "$TS_UP_PID_FILE" ] || [ -L "$TS_UP_PID_FILE" ]; then
        # B4.1: kill only a root-owned pidfile whose pid is really tailscale
        old_pid=$(qm_read_pid "$TS_UP_PID_FILE" tailscale) && kill "$old_pid" 2>/dev/null
        rm -f "$TS_UP_PID_FILE"
    fi
}

# --- Helper: refuse to mutate while an install/update/OTA migration runs -----
# The lock holds a pid; a dead (or untrusted) holder is stale and is cleared
# here so a crashed worker can never wedge the page.
check_migration_lock() {
    if [ -e "$TS_LOCK_FILE" ] || [ -L "$TS_LOCK_FILE" ]; then
        if ts_lock_holder >/dev/null; then
            cgi_error "migration_in_progress" "A Tailscale install or update is in progress, try again in a moment"
            exit 0
        fi
        rm -f "$TS_LOCK_FILE"
    fi
}

# --- Helper: refuse to start a worker while one runs -------------------------
# Our own install/update worker -> already_running; install.sh -> migration.
check_worker_lock() {
    local held_op
    if held_op=$(ts_lock_op); then
        case "$held_op" in
            install|update)
                cgi_error "already_running" "A Tailscale install or update is already running"
                ;;
            *)
                cgi_error "migration_in_progress" "A Tailscale install or update is in progress, try again in a moment"
                ;;
        esac
        exit 0
    fi
}

# --- Helper: get tailscale version string ------------------------------------
get_ts_version() {
    tailscale version 2>/dev/null | head -1 | awk '{print $1}'
}

# --- Helper: spawn an orphaned install/update worker -------------------------
# The CGI takes the lock first (so a second click cannot start a second
# worker), writes a fresh "running" progress (so install_status never shows the
# previous run's terminal state), then the worker takes the lock over.
spawn_ts_worker() {
    local op
    local source
    op="$1"
    source="${2:-official}"
    if ! qm_run_dir >/dev/null; then
        cgi_error "${op}_failed" "Cannot prepare the install state directory"
        exit 0
    fi
    if ! ts_lock_acquire "$op"; then
        check_worker_lock
        cgi_error "already_running" "A Tailscale install or update is already running"
        exit 0
    fi
    : > "$TS_INSTALL_LOG"
    TS_OP="$op"
    TS_SOURCE="$source"
    ts_progress running "Starting..." >/dev/null
    if [ "$op" = "update" ]; then
        ( ts_do_update ) </dev/null >>"$TS_INSTALL_LOG" 2>&1 &
    else
        ( ts_do_install "$source" ) </dev/null >>"$TS_INSTALL_LOG" 2>&1 &
    fi
}

# --- Helper: re-assert reachability on connect / daemon start ----------------
# The ip rules are synchronous and cheap. A missing zone is written to UCI now
# and fw4 is reloaded from the EXIT trap, after the response has been written.
TS_FW_RELOAD_PENDING=0
ts_net_prep() {
    ts_net_owned || return 0
    ts_net_enabled || return 0
    ts_net_ensure_rules
    if ! ts_net_zone_present; then
        ts_net_ensure_zone && TS_FW_RELOAD_PENDING=1
    fi
    return 0
}
_ts_cgi_exit() {
    if [ "$TS_FW_RELOAD_PENDING" = "1" ]; then
        TS_FW_RELOAD_PENDING=0
        ( ( sleep 1; ts_net_fw_reload ) </dev/null >/dev/null 2>&1 & )
    fi
}
trap '_ts_cgi_exit' EXIT

# --- Helper: Tiny-build connect over the LocalAPI ----------------------------
# The Tiny build omits the IPN bus, so `tailscale up` / `login` return without
# setting prefs or starting a login. Same result as `tailscale up
# --accept-dns=false` through EditPrefs, so no other pref (SSH, exit node) is
# reset: WantRunning on, CorpDNS off, then an interactive login when the node
# needs one. Prints the CGI response.
TS_LOCALAPI_SOCK="/var/run/tailscale/tailscaled.sock"
# ts_localapi METHOD PATH [JSON] — prints the HTTP status code.
ts_localapi() {
    curl -s --max-time 5 --unix-socket "$TS_LOCALAPI_SOCK" -o /dev/null -w '%{http_code}' \
        -X "$1" -H 'Content-Type: application/json' -d "${3:-}" \
        "http://local-tailscaled.sock/localapi/v0/$2" 2>/dev/null
}

ts_tiny_connect() {
    local code
    local st
    local state
    local url
    local n
    local asked
    code=$(ts_localapi PATCH prefs '{"WantRunningSet":true,"WantRunning":true,"CorpDNSSet":true,"CorpDNS":false}')
    case "$code" in
        2*) : ;;
        *)
            qlog_error "LocalAPI prefs edit failed (HTTP ${code:-none})"
            cgi_error "connect_failed" "Could not reach the Tailscale daemon"
            return 0
            ;;
    esac
    asked=0
    n=0
    while [ "$n" -lt 10 ]; do
        st=$(tailscale status --json 2>/dev/null)
        state=$(printf '%s' "$st" | jq -r '.BackendState // ""' 2>/dev/null)
        url=$(printf '%s' "$st" | jq -r '.AuthURL // ""' 2>/dev/null)
        if [ "$state" = "Running" ]; then
            rm -f "$AUTH_URL_FILE"
            qlog_info "Tailscale already authenticated"
            jq -n '{"success": true, "already_authenticated": true}'
            return 0
        fi
        if [ -n "$url" ]; then
            printf '%s' "$url" | qm_atomic_write "$AUTH_URL_FILE"
            qlog_info "Auth URL generated, waiting for user authentication"
            jq -n --arg auth_url "$url" '{"success": true, "auth_url": $auth_url}'
            return 0
        fi
        if [ "$state" = "NeedsLogin" ] && [ "$asked" = "0" ]; then
            ts_localapi POST login-interactive >/dev/null
            asked=1
        fi
        sleep 1
        n=$((n + 1))
    done
    qlog_error "Timed out waiting for auth URL"
    cgi_error "auth_timeout" "Timed out waiting for auth URL. Check if tailscaled is running."
    return 0
}

# =============================================================================
# GET — Fetch installation status, daemon state, connection info, peers
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then

    if command -v netbird >/dev/null 2>&1; then
        other_vpn_installed="true"
    else
        other_vpn_installed="false"
    fi

    # --- Busy: an install / update worker (or OTA migration) holds the lock --
    if busy_op=$(ts_lock_op); then
        [ "$busy_op" = "update" ] || busy_op="install"
        jq -n --arg busy "$busy_op" '{success: true, installed: true, busy: $busy}'
        exit 0
    fi

    # Whether the firmware trusts the Tiny build's signed feed (picker gate).
    tiny_available="false"
    ts_tiny_available && tiny_available="true"

    # --- Tier 1: Not installed -----------------------------------------------
    if ! is_installed; then
        qlog_info "Tailscale not installed"
        jq -n \
            --argjson other_vpn_installed "$other_vpn_installed" \
            --argjson tiny_available "$tiny_available" \
            '{
                success: true,
                installed: false,
                tiny_available: $tiny_available,
                other_vpn_installed: $other_vpn_installed,
                other_vpn_name: "NetBird"
            }'
        exit 0
    fi

    ts_version=$(get_ts_version)
    boot_enabled=$(get_boot_enabled)
    install_variant=$(ts_variant)

    # Update facts. latest_version comes from the source's cache only
    # (check_update refreshes it); this GET never waits on the network.
    update_available="false"
    legacy_build="false"
    latest_version=""
    case "$install_variant" in
        official|tiny)
            TS_SOURCE="$install_variant"
            latest_version=$(ts_latest_cache_read)
            if [ -n "$latest_version" ] && ts_version_gt "$latest_version" "$(ts_compare_version)"; then
                update_available="true"
            fi
            ;;
        opkg) legacy_build="true" ;;
    esac
    # Network fixes belong to QManager only off the Tiny build (whose own init
    # owns the zone and rules); null is dropped from the payload below.
    net_fixes_enabled="null"
    if ts_net_owned; then
        net_fixes_enabled="false"
        ts_net_enabled && net_fixes_enabled="true"
    fi

    # --- Tier 2: Installed but daemon not running ----------------------------
    if ! is_daemon_running; then
        qlog_info "Tailscale installed but daemon not running"
        jq -n \
            --argjson installed true \
            --argjson daemon_running false \
            --argjson enabled_on_boot "$boot_enabled" \
            --arg version "$ts_version" \
            --arg install_variant "$install_variant" \
            --arg latest_version "$latest_version" \
            --argjson update_available "$update_available" \
            --argjson legacy_build "$legacy_build" \
            --argjson net_fixes_enabled "$net_fixes_enabled" \
            --argjson tiny_available "$tiny_available" \
            --argjson other_vpn_installed "$other_vpn_installed" \
            '{
                success: true,
                installed: $installed,
                daemon_running: $daemon_running,
                enabled_on_boot: $enabled_on_boot,
                version: $version,
                install_variant: $install_variant,
                latest_version: $latest_version,
                update_available: $update_available,
                legacy_build: $legacy_build,
                net_fixes_enabled: $net_fixes_enabled,
                tiny_available: $tiny_available,
                other_vpn_installed: $other_vpn_installed,
                other_vpn_name: "NetBird"
            } | if .net_fixes_enabled == null then del(.net_fixes_enabled) else . end'
        exit 0
    fi

    # --- Tier 3: Daemon running — fetch full status --------------------------
    qlog_info "Fetching tailscale status"

    # Use timeout if available to prevent hangs
    if command -v timeout >/dev/null 2>&1; then
        status_json=$(timeout 5 tailscale status --json 2>/dev/null)
    else
        status_json=$(tailscale status --json 2>/dev/null)
    fi

    if [ -z "$status_json" ] || ! printf '%s' "$status_json" | jq -e . >/dev/null 2>&1; then
        qlog_error "Failed to get tailscale status JSON"
        jq -n \
            --argjson installed true \
            --argjson daemon_running true \
            --argjson enabled_on_boot "$boot_enabled" \
            --arg version "$ts_version" \
            --arg install_variant "$install_variant" \
            --arg latest_version "$latest_version" \
            --argjson update_available "$update_available" \
            --argjson legacy_build "$legacy_build" \
            --argjson net_fixes_enabled "$net_fixes_enabled" \
            --argjson tiny_available "$tiny_available" \
            '{
                success: true,
                installed: $installed,
                daemon_running: $daemon_running,
                enabled_on_boot: $enabled_on_boot,
                version: $version,
                install_variant: $install_variant,
                latest_version: $latest_version,
                update_available: $update_available,
                legacy_build: $legacy_build,
                net_fixes_enabled: $net_fixes_enabled,
                tiny_available: $tiny_available,
                backend_state: "Unknown",
                error_detail: "Could not retrieve status from tailscale daemon"
            } | if .net_fixes_enabled == null then del(.net_fixes_enabled) else . end'
        exit 0
    fi

    # Extract backend state
    backend_state=$(printf '%s' "$status_json" | jq -r '.BackendState // "Unknown"')

    # Extract auth URL (from status JSON or persisted file)
    auth_url=$(printf '%s' "$status_json" | jq -r '.AuthURL | if . == null then empty else . end')
    if [ -z "$auth_url" ] && [ -f "$AUTH_URL_FILE" ]; then
        auth_url=$(cat "$AUTH_URL_FILE" 2>/dev/null)
    fi
    # Clear persisted auth URL if we're now running
    if [ "$backend_state" = "Running" ] && [ -f "$AUTH_URL_FILE" ]; then
        rm -f "$AUTH_URL_FILE"
        auth_url=""
    fi

    # Build self object from .Self
    self_json=$(printf '%s' "$status_json" | jq '{
        hostname: (.Self.HostName // ""),
        dns_name: (.Self.DNSName // ""),
        tailscale_ips: [(.Self.TailscaleIPs // [])[] | tostring],
        online: (.Self.Online // false),
        os: (.Self.OS // ""),
        relay: (.Self.Relay // "")
    }' 2>/dev/null) || self_json='{}'

    # Build tailnet object from .CurrentTailnet
    tailnet_json=$(printf '%s' "$status_json" | jq '{
        name: (.CurrentTailnet.Name // ""),
        magic_dns_suffix: (.CurrentTailnet.MagicDNSSuffix // .MagicDNSSuffix // ""),
        magic_dns_enabled: (.CurrentTailnet.MagicDNSEnabled // false)
    }' 2>/dev/null) || tailnet_json='{}'

    # Build peers array from .Peer (map keyed by public key)
    peers_json=$(printf '%s' "$status_json" | jq '[
        (.Peer // {}) | to_entries[] | .value | {
            hostname: (.HostName // ""),
            dns_name: (.DNSName // ""),
            tailscale_ips: [(.TailscaleIPs // [])[] | tostring],
            os: (.OS // ""),
            online: (.Online // false),
            last_seen: (.LastSeen // ""),
            relay: (.Relay // ""),
            exit_node: (.ExitNode // false)
        }
    ]' 2>/dev/null) || peers_json='[]'

    # Extract health warnings
    health_json=$(printf '%s' "$status_json" | jq '.Health // []' 2>/dev/null) || health_json='[]'

    # Whether this device currently advertises itself as an exit node. Extracted
    # top-level (like backend_state) for the hook's convenience. .Self.ExitNodeOption
    # is true when --advertise-exit-node is set on the local prefs.
    exit_node_advertised=$(printf '%s' "$status_json" | jq -r '.Self.ExitNodeOption // false' 2>/dev/null)
    [ "$exit_node_advertised" = "true" ] || exit_node_advertised="false"

    # Tailscale SSH server state, from tailscaled's own persisted prefs (our
    # connect never passes --reset, so tailscaled is the single source of truth).
    # null when the prefs can't be read (e.g. a build without `debug prefs`).
    if command -v timeout >/dev/null 2>&1; then
        prefs_json=$(timeout 5 tailscale debug prefs 2>/dev/null)
    else
        prefs_json=$(tailscale debug prefs 2>/dev/null)
    fi
    ssh_enabled=$(printf '%s' "$prefs_json" | jq -r '.RunSSH | if type == "boolean" then tostring else empty end' 2>/dev/null)
    case "$ssh_enabled" in
        true|false) : ;;
        *) ssh_enabled="null" ;;
    esac

    # Assemble full response
    jq -n \
        --argjson installed true \
        --argjson daemon_running true \
        --argjson enabled_on_boot "$boot_enabled" \
        --arg version "$ts_version" \
        --arg backend_state "$backend_state" \
        --arg auth_url "$auth_url" \
        --arg install_variant "$install_variant" \
        --arg latest_version "$latest_version" \
        --argjson update_available "$update_available" \
        --argjson legacy_build "$legacy_build" \
        --argjson net_fixes_enabled "$net_fixes_enabled" \
        --argjson tiny_available "$tiny_available" \
        --argjson exit_node_advertised "$exit_node_advertised" \
        --argjson ssh_enabled "$ssh_enabled" \
        --argjson self "$self_json" \
        --argjson tailnet "$tailnet_json" \
        --argjson peers "$peers_json" \
        --argjson health "$health_json" \
        --argjson other_vpn_installed "$other_vpn_installed" \
        '{
            success: true,
            installed: $installed,
            daemon_running: $daemon_running,
            enabled_on_boot: $enabled_on_boot,
            version: $version,
            install_variant: $install_variant,
            latest_version: $latest_version,
            update_available: $update_available,
            legacy_build: $legacy_build,
            net_fixes_enabled: $net_fixes_enabled,
            tiny_available: $tiny_available,
            backend_state: $backend_state,
            exit_node_advertised: $exit_node_advertised,
            ssh_enabled: $ssh_enabled,
            auth_url: $auth_url,
            self: $self,
            tailnet: $tailnet,
            peers: $peers,
            health: $health,
            other_vpn_installed: $other_vpn_installed,
            other_vpn_name: "NetBird"
        } | if .net_fixes_enabled == null then del(.net_fixes_enabled) else . end'
    exit 0
fi

# =============================================================================
# POST — Actions: connect, disconnect, logout, start/stop service, boot toggle
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty')

    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: install — {source?: "official"|"tiny"}, background worker.
    # "variant" is accepted as an alias for older clients; absent = official.
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "install" ]; then
        SOURCE=$(printf '%s' "$POST_DATA" | jq -r '(.source // .variant) | if . == null then empty else tostring end')
        case "$SOURCE" in
            "") SOURCE="official" ;;
            official|tiny) : ;;
            *)
                cgi_error "invalid_variant" "source must be 'official' or 'tiny'"
                exit 0
                ;;
        esac
        if [ "$SOURCE" = "tiny" ] && ! ts_tiny_available; then
            cgi_error "feed_unavailable" "The Tiny build is not available on this device"
            exit 0
        fi

        check_worker_lock

        # Mutual exclusion: refuse if other VPN is installed
        if command -v netbird >/dev/null 2>&1; then
            cgi_error "other_vpn_installed" "NetBird is already installed. Uninstall it before installing Tailscale."
            exit 0
        fi

        # Already installed?
        if is_installed; then
            cgi_error "already_installed" "Tailscale is already installed"
            exit 0
        fi

        qlog_info "Starting Tailscale installation ($SOURCE)"
        spawn_ts_worker install "$SOURCE"
        cgi_success
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: install_status — poll install progress + live log tail
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "install_status" ]; then
        if [ -f "$TS_INSTALL_RESULT" ]; then
            status_json=$(cat "$TS_INSTALL_RESULT" 2>/dev/null)
        else
            status_json='{"success":true,"status":"idle"}'
        fi
        # A half-written status file must not break the poller's JSON.
        if ! printf '%s' "$status_json" | jq -e . >/dev/null 2>&1; then
            status_json='{"success":true,"status":"running","message":"Installing..."}'
        fi
        # A worker that died (OOM, kill -9, power-off) never writes its
        # terminal state. "running" with no live lock holder, older than a
        # 10 s grace (the CGI pre-writes "Starting..." before the worker takes
        # the lock), is turned into an error and written back.
        st_status=$(printf '%s' "$status_json" | jq -r '.status // ""' 2>/dev/null)
        if [ "$st_status" = "running" ] && [ -f "$TS_INSTALL_RESULT" ] && ! ts_lock_holder >/dev/null; then
            st_mtime=$(_ts_num "$(stat -c %Y "$TS_INSTALL_RESULT" 2>/dev/null)")
            st_age=$(( $(_ts_now) - st_mtime ))
            if [ "$st_mtime" -gt 0 ] && [ "$st_age" -ge 10 ]; then
                st_op=$(printf '%s' "$status_json" | jq -r '.op // "install"' 2>/dev/null)
                case "$st_op" in
                    update) st_msg="The Tailscale update stopped unexpectedly" ;;
                    *) st_op="install"; st_msg="The Tailscale install stopped unexpectedly" ;;
                esac
                status_json=$(jq -cn --arg op "$st_op" --arg error "${st_op}_failed" --arg message "$st_msg" \
                    '{success: false, status: "error", op: $op, error: $error, message: $message}')
                printf '%s' "$status_json" | qm_atomic_write "$TS_INSTALL_RESULT"
            fi
        fi
        # CR -> LF first so \r-separated progress output lands on its own lines.
        log_tail=""
        if [ -f "$TS_INSTALL_LOG" ]; then
            log_tail=$(tr '\r' '\n' < "$TS_INSTALL_LOG" 2>/dev/null | tr -d '\000' | tail -n 50)
        fi
        printf '%s' "$status_json" | jq --arg log "$log_tail" '. + {log: $log}'
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: set_net_fixes — the automatic zone + routing fixes on/off.
    # UCI is written now; apply / teardown (which may reload fw4) runs in an
    # orphaned worker after the response.
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "set_net_fixes" ]; then
        check_migration_lock
        # The Tiny build's init owns its zone and rules; a teardown here would
        # delete the zone it relies on.
        if is_installed && ! ts_net_owned; then
            cgi_error "not_applicable" "Network fixes are managed by the Tiny build"
            exit 0
        fi
        nf_value=$(printf '%s' "$POST_DATA" | jq -r '.enabled | if . == null then empty else tostring end')
        case "$nf_value" in
            true) nf_uci=1 ;;
            false) nf_uci=0 ;;
            "")
                cgi_error "missing_field" "enabled field is required"
                exit 0
                ;;
            *)
                cgi_error "invalid_value" "enabled must be true or false"
                exit 0
                ;;
        esac
        uci -q get quecmanager.tailscale_net >/dev/null 2>&1 \
            || uci set quecmanager.tailscale_net=tailscale_net
        uci set quecmanager.tailscale_net.enabled="$nf_uci"
        if ! uci commit quecmanager; then
            cgi_error "save_failed" "Could not save the setting"
            exit 0
        fi
        qlog_info "Tailscale network fixes set to $nf_value"
        jq -n --argjson enabled "$nf_value" '{success: true, enabled: $enabled}'
        # The job re-reads UCI after the delay, so two quick toggles always
        # converge on the value saved last.
        ( (
            sleep 1
            if ts_net_enabled; then
                is_installed && ts_net_apply
            else
                ts_net_teardown
            fi
        ) </dev/null >/dev/null 2>&1 & )
        exit 0
    fi

    # All remaining POST actions require tailscale to be installed
    if ! is_installed; then
        cgi_error "not_installed" "Tailscale is not installed"
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: check_update — latest version of the installed source (official:
    # pkgs.tailscale.com, tiny: the feed index), cached (6 h, 30 min after a
    # failed check). force:true always asks the source.
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "check_update" ]; then
        cu_force=$(printf '%s' "$POST_DATA" | jq -r 'if .force == true then "1" else "0" end' 2>/dev/null)
        cu_variant=$(ts_variant)
        if [ "$cu_variant" = "opkg" ]; then
            cgi_error "legacy_build" "This Tailscale build cannot be updated here"
            exit 0
        fi
        TS_SOURCE="$cu_variant"
        cu_installed=$(ts_compare_version)
        if [ "$cu_force" = "1" ] || ts_latest_cache_due; then
            # Bounded for a synchronous request: 2 attempts of 20 s.
            TS_FETCH_RETRY=1
            if ! ts_latest_refresh; then
                cgi_error "update_check_failed" "Could not check for Tailscale updates"
                exit 0
            fi
        fi
        cu_latest=$(ts_latest_cache_read)
        if [ -z "$cu_latest" ]; then
            cgi_error "update_check_failed" "Could not check for Tailscale updates"
            exit 0
        fi
        cu_checked=$(_ts_num "$(_ts_cache_field checked_at)")
        cu_available="false"
        if ts_version_gt "$cu_latest" "$cu_installed"; then
            cu_available="true"
        fi
        jq -n \
            --arg installed_version "$cu_installed" \
            --arg latest_version "$cu_latest" \
            --argjson update_available "$cu_available" \
            --argjson checked_at "$cu_checked" \
            '{
                success: true,
                installed_version: $installed_version,
                latest_version: $latest_version,
                update_available: $update_available,
                checked_at: $checked_at
            }'
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: update — official and tiny, background worker. The worker
    # re-checks the version, installs (binary swap or opkg), restarts,
    # health-checks and rolls back on failure (install_status, op "update").
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "update" ]; then
        up_variant=$(ts_variant)
        case "$up_variant" in
            official|tiny) TS_SOURCE="$up_variant" ;;
            *)
                cgi_error "legacy_build" "This Tailscale build cannot be updated here. Uninstall it, then install it again."
                exit 0
                ;;
        esac
        check_worker_lock
        up_installed=$(ts_compare_version)
        up_latest=$(ts_latest_cache_read)
        # An unreadable installed version goes to the worker, which reports it.
        if [ -n "$up_latest" ] && [ -n "$up_installed" ] && ! ts_version_gt "$up_latest" "$up_installed"; then
            cgi_error "up_to_date" "Tailscale is already up to date"
            exit 0
        fi
        qlog_info "Starting Tailscale update from $up_installed ($up_variant)"
        spawn_ts_worker update "$up_variant"
        cgi_success
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: connect — start tailscale up, capture auth URL
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "connect" ]; then
        check_migration_lock
        qlog_info "Connecting to Tailscale"

        # Ensure daemon is running first
        if ! is_daemon_running; then
            if [ -x /etc/init.d/tailscale ]; then
                /etc/init.d/tailscale start >/dev/null 2>&1
            else
                tailscaled --state=/etc/tailscale/tailscaled.state >/dev/null 2>&1 &
            fi
            # Wait for daemon to be ready (up to 5 seconds)
            attempts=0
            while [ "$attempts" -lt 5 ]; do
                sleep 1
                is_daemon_running && break
                attempts=$((attempts + 1))
            done
            if ! is_daemon_running; then
                cgi_error "daemon_start_failed" "Could not start tailscale daemon"
                exit 0
            fi
        fi

        # Auto-enable boot persistence on connect for the OFFICIAL variant so
        # the node reconnects after a reboot without the user re-clicking
        # Connect. The tiny/opkg variant manages its own boot lifecycle and is
        # left untouched. Writes both the UCI flag and the init.d enable so the
        # two stay in lockstep (get_boot_enabled reads UCI first).
        if [ "$(ts_variant)" = "official" ]; then
            uci -q get tailscale.settings >/dev/null 2>&1 || ts_seed_uci_settings
            uci -q set tailscale.settings.service_enabled='1' 2>/dev/null
            uci -q commit tailscale 2>/dev/null
            [ -x /etc/init.d/tailscale ] && /etc/init.d/tailscale enable >/dev/null 2>&1
        fi

        # Reachability: pref-1990 rule now, zone (if missing) after the response.
        ts_net_prep

        # Kill any stale tailscale up process from a previous attempt
        kill_stale_ts_up

        # Clean up old temp files
        rm -f "$AUTH_URL_FILE" "$TS_UP_OUTPUT"
        qm_run_dir >/dev/null || { cgi_error "start_failed" "Cannot prepare work dir"; exit 0; }

        # The Tiny build omits the IPN bus; connect through the LocalAPI.
        if [ "$(ts_variant)" = "tiny" ]; then
            ts_tiny_connect
            exit 0
        fi

        # CRITICAL: NEVER use --accept-routes or --advertise-routes — accepting
        # routes disconnects the device from the network entirely and requires
        # a physical reboot to recover. Route advertising is banned by design.
        # Run tailscale up as a fully orphaned background job so it survives
        # this CGI exiting. The previous pattern — `( cmd ) &` without stdin
        # redirection — kept the process in the CGI's process group, so when
        # uhttpd closed the HTTP connection the child got SIGHUP/SIGPIPE'd.
        # That killed `tailscale up` before it could push the post-auth prefs
        # to tailscaled, and the admin console showed "registered but
        # disconnected" until the user stopped/started the service and
        # re-authenticated. The double-fork form below (inner `&`, </dev/null)
        # orphans tailscale up to init before the CGI returns.
        ( tailscale up --accept-dns=false --json </dev/null >"$TS_UP_OUTPUT" 2>&1 &
          echo $! | qm_atomic_write "$TS_UP_PID_FILE"
        )

        # Poll for auth URL or Running state (up to 10 seconds)
        attempts=0
        auth_url=""
        while [ "$attempts" -lt 10 ]; do
            sleep 1
            if [ -f "$TS_UP_OUTPUT" ] && [ -s "$TS_UP_OUTPUT" ]; then
                # Check if already authenticated (BackendState = Running)
                state=$(jq -r 'select(.BackendState == "Running") | .BackendState' "$TS_UP_OUTPUT" 2>/dev/null | head -1)
                if [ "$state" = "Running" ]; then
                    rm -f "$AUTH_URL_FILE" "$TS_UP_PID_FILE"
                    qlog_info "Tailscale already authenticated"
                    jq -n '{"success": true, "already_authenticated": true}'
                    exit 0
                fi
                # Look for auth URL in JSON stream
                auth_url=$(jq -r 'select(.AuthURL != null and .AuthURL != "") | .AuthURL' "$TS_UP_OUTPUT" 2>/dev/null | head -1)
                if [ -n "$auth_url" ]; then
                    printf '%s' "$auth_url" | qm_atomic_write "$AUTH_URL_FILE"
                    break
                fi
            fi
            attempts=$((attempts + 1))
        done

        if [ -n "$auth_url" ]; then
            qlog_info "Auth URL generated, waiting for user authentication"
            jq -n --arg auth_url "$auth_url" '{"success": true, "auth_url": $auth_url}'
        else
            qlog_error "Timed out waiting for auth URL"
            cgi_error "auth_timeout" "Timed out waiting for auth URL. Check if tailscaled is running."
        fi
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: disconnect — disconnect from tailnet (stay registered)
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "disconnect" ]; then
        check_migration_lock
        qlog_info "Disconnecting Tailscale"
        result=$(tailscale down 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            qlog_error "tailscale down failed: $result"
            cgi_error "disconnect_failed" "Failed to disconnect: $result"
            exit 0
        fi
        rm -f "$AUTH_URL_FILE"
        qlog_info "Tailscale disconnected"
        cgi_success
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: logout — full deauthentication (removes device from tailnet)
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "logout" ]; then
        check_migration_lock
        qlog_info "Logging out of Tailscale"
        kill_stale_ts_up
        result=$(tailscale logout 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            qlog_error "tailscale logout failed: $result"
            cgi_error "logout_failed" "Failed to logout: $result"
            exit 0
        fi
        rm -f "$AUTH_URL_FILE" "$TS_UP_OUTPUT" "$TS_UP_PID_FILE"
        qlog_info "Tailscale logged out"
        cgi_success
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: start_service — start tailscaled daemon
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "start_service" ]; then
        check_migration_lock
        if is_daemon_running; then
            cgi_error "already_running" "Tailscale daemon is already running"
            exit 0
        fi
        qlog_info "Starting tailscale daemon"
        if [ -x /etc/init.d/tailscale ]; then
            /etc/init.d/tailscale start >/dev/null 2>&1
        else
            tailscaled --state=/etc/tailscale/tailscaled.state >/dev/null 2>&1 &
        fi
        sleep 1
        if is_daemon_running; then
            qlog_info "Tailscale daemon started"
            ts_net_prep
            cgi_success
        else
            cgi_error "start_failed" "Failed to start tailscale daemon"
        fi
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: stop_service — stop tailscaled daemon
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "stop_service" ]; then
        check_migration_lock
        qlog_info "Stopping tailscale daemon"
        kill_stale_ts_up
        if [ -x /etc/init.d/tailscale ]; then
            /etc/init.d/tailscale stop >/dev/null 2>&1
        else
            killall tailscaled 2>/dev/null
        fi
        rm -f "$AUTH_URL_FILE" "$TS_UP_OUTPUT" "$TS_UP_PID_FILE"
        qlog_info "Tailscale daemon stopped"
        cgi_success
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: set_boot_enabled — enable/disable tailscale on boot
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "set_boot_enabled" ]; then
        check_migration_lock
        boot_enabled=$(printf '%s' "$POST_DATA" | jq -r '.enabled | if . == null then empty else tostring end')
        if [ -z "$boot_enabled" ]; then
            cgi_error "missing_field" "enabled field is required"
            exit 0
        fi
        if [ ! -x /etc/init.d/tailscale ]; then
            cgi_error "no_init_script" "Tailscale init script not found"
            exit 0
        fi
        case "$boot_enabled" in
            true)
                # Toggle UCI flag (authoritative for luci-app-tailscale-community-tiny)
                if uci -q get tailscale.settings >/dev/null 2>&1; then
                    uci set tailscale.settings.service_enabled='1'
                    uci commit tailscale
                fi
                /etc/init.d/tailscale enable >/dev/null 2>&1
                qlog_info "Tailscale enabled on boot"
                ;;
            false)
                if uci -q get tailscale.settings >/dev/null 2>&1; then
                    uci set tailscale.settings.service_enabled='0'
                    uci commit tailscale
                fi
                /etc/init.d/tailscale disable >/dev/null 2>&1
                qlog_info "Tailscale disabled on boot"
                ;;
            *)
                cgi_error "invalid_value" "enabled must be true or false"
                exit 0
                ;;
        esac
        cgi_success
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: set_ssh — turn the Tailscale SSH server on/off while connected.
    # `tailscale set` keeps every other pref, and tailscaled persists RunSSH
    # itself, so QManager stores no copy (the GET reads it back from prefs).
    # Who may SSH in is still governed by the tailnet's ACL policy.
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "set_ssh" ]; then
        check_migration_lock
        ssh_value=$(printf '%s' "$POST_DATA" | jq -r '.enabled | if . == null then empty else tostring end')
        if [ -z "$ssh_value" ]; then
            cgi_error "missing_field" "enabled field is required"
            exit 0
        fi
        case "$ssh_value" in
            true|false) : ;;
            *)
                cgi_error "invalid_value" "enabled must be true or false"
                exit 0
                ;;
        esac

        if ! is_daemon_running; then
            cgi_error "not_connected" "Tailscale must be connected to change Tailscale SSH"
            exit 0
        fi
        if command -v timeout >/dev/null 2>&1; then
            ssh_status=$(timeout 5 tailscale status --json 2>/dev/null)
        else
            ssh_status=$(tailscale status --json 2>/dev/null)
        fi
        ssh_state=$(printf '%s' "$ssh_status" | jq -r '.BackendState // "Unknown"' 2>/dev/null)
        if [ "$ssh_state" != "Running" ]; then
            cgi_error "not_connected" "Tailscale must be connected to change Tailscale SSH"
            exit 0
        fi

        ssh_result=$(tailscale set --ssh="$ssh_value" 2>&1)
        ssh_rc=$?
        if [ "$ssh_rc" -ne 0 ]; then
            qlog_error "tailscale set --ssh=$ssh_value failed: $ssh_result"
            cgi_error "set_failed" "Failed to update Tailscale SSH: $ssh_result"
            exit 0
        fi
        qlog_info "Tailscale SSH set to $ssh_value"
        cgi_success
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: set_exit_node — opt-in advertise this device as a Tailscale exit
    # node, applied only while Tailscale is connected. Uses `tailscale set` (NOT
    # `tailscale up`, which would reset every pref we didn't pass). Advertising
    # an exit node still requires the user to APPROVE it in the Tailscale admin
    # console before peers can route through it; any IP-forwarding warning
    # surfaces via the `health` array in the GET status response.
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "set_exit_node" ]; then
        check_migration_lock
        exit_node_enabled=$(printf '%s' "$POST_DATA" | jq -r '.enabled | if . == null then empty else tostring end')
        if [ -z "$exit_node_enabled" ]; then
            cgi_error "missing_field" "enabled field is required"
            exit 0
        fi
        case "$exit_node_enabled" in
            true|false) : ;;
            *)
                cgi_error "invalid_value" "enabled must be true or false"
                exit 0
                ;;
        esac

        # Daemon must be up.
        if ! is_daemon_running; then
            cgi_error "not_connected" "Tailscale must be connected to change exit-node advertising"
            exit 0
        fi

        # Require authenticated/Running backend state.
        if command -v timeout >/dev/null 2>&1; then
            en_status=$(timeout 5 tailscale status --json 2>/dev/null)
        else
            en_status=$(tailscale status --json 2>/dev/null)
        fi
        en_state=$(printf '%s' "$en_status" | jq -r '.BackendState // "Unknown"' 2>/dev/null)
        if [ "$en_state" != "Running" ]; then
            cgi_error "not_connected" "Tailscale must be connected to change exit-node advertising"
            exit 0
        fi

        # Apply via `tailscale set` so unspecified prefs are preserved.
        en_result=$(tailscale set --advertise-exit-node="$exit_node_enabled" 2>&1)
        en_rc=$?
        if [ "$en_rc" -ne 0 ]; then
            qlog_error "tailscale set --advertise-exit-node=$exit_node_enabled failed: $en_result"
            cgi_error "set_failed" "Failed to update exit-node advertising: $en_result"
            exit 0
        fi
        qlog_info "Exit-node advertising set to $exit_node_enabled"
        cgi_success
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: uninstall — remove tailscale packages from the device
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "uninstall" ]; then
        check_migration_lock
        qlog_info "Uninstalling Tailscale packages"

        # Stop service if running.
        if is_daemon_running; then
            qlog_info "Stopping Tailscale daemon before uninstall"
            kill_stale_ts_up
            tailscale down >/dev/null 2>&1
            if [ -x /etc/init.d/tailscale ]; then
                /etc/init.d/tailscale stop >/dev/null 2>&1
            else
                killall tailscaled 2>/dev/null
            fi
            sleep 1
        fi

        # Disable boot entry if init script exists (covers official, legacy, tiny).
        [ -x /etc/init.d/tailscale ] && /etc/init.d/tailscale disable >/dev/null 2>&1

        # Method-aware removal. Official (tarball) installs have no opkg entry —
        # remove the binaries, the heredoc-written init script, its rc.d symlinks
        # and the UCI section directly. Everything else goes through the existing
        # 6-package smart opkg removal.
        un_variant=$(ts_variant)
        if [ "$un_variant" = "official" ]; then
            qlog_info "Removing official (tarball) Tailscale install"
            rm -f /usr/bin/tailscale /usr/bin/tailscaled /etc/init.d/tailscale
            rm -f /usr/bin/.tailscale.old /usr/bin/.tailscaled.old /usr/bin/.tailscale.new /usr/bin/.tailscaled.new
            rm -f /etc/rc.d/*tailscale 2>/dev/null
            uci -q delete tailscale 2>/dev/null && uci -q commit tailscale 2>/dev/null
            # uci delete+commit does NOT remove /etc/config/tailscale on-device —
            # the section resurrects on next read. Remove the file outright.
            rm -f /etc/config/tailscale 2>/dev/null || true
        else
            # Smart removal: enumerate which of the 6 known package names are
            # installed and remove only those. Handles pure-legacy, pure-tiny,
            # and any partial state.
            PKGS=$(opkg list-installed 2>/dev/null | awk '{print $1}' | grep -E \
                '^(tailscale|tailscaled|tailscale-tiny|luci-app-tailscale|luci-app-tailscale-community|luci-app-tailscale-community-tiny)$' \
                | tr '\n' ' ')
            if [ -n "$PKGS" ]; then
                qlog_info "Removing packages: $PKGS"
                opkg remove $PKGS >/dev/null 2>&1
            else
                qlog_info "No Tailscale packages found to remove"
            fi
            if [ "$un_variant" = "tiny" ]; then
                # The package's init created network.tailscale (proto none on
                # tailscale0); its zone goes with ts_net_teardown below. opkg
                # keeps a modified conffile, and a leftover file resurrects
                # the UCI section.
                if [ "$(uci -q get network.tailscale.proto)" = "none" ] \
                        && [ "$(uci -q get network.tailscale.device)" = "tailscale0" ]; then
                    uci -q delete network.tailscale && uci -q commit network
                fi
                rm -f /etc/config/tailscale /etc/config/tailscale-opkg 2>/dev/null
                # Only once the package is really gone: its init owns them.
                [ -f /usr/lib/opkg/info/tailscale-tiny.control ] || ts_net_remove_tiny_rules
            fi
        fi

        # Clean up state from official, legacy and tiny locations (marker lives
        # in /etc/tailscale, removed here).
        rm -rf /var/lib/tailscale/ /etc/tailscale/
        rm -f /tmp/qmanager_tailscale_auth_url /tmp/qmanager_tailscale_up_output /var/run/qmanager/tailscale_up_output /tmp/qmanager_tailscale_up_pid
        rm -f "$TS_LATEST_CACHE" "$TS_TINY_CACHE"

        # Verify removal (check actual binary paths, not command -v which can be cached).
        hash -r 2>/dev/null
        if [ -x /usr/sbin/tailscale ] || [ -x /usr/bin/tailscale ] || [ -x /usr/sbin/tailscaled ]; then
            qlog_error "Tailscale binary still present after opkg remove"
            cgi_error "uninstall_failed" "Failed to remove Tailscale packages"
            exit 0
        fi

        qlog_info "Tailscale uninstalled successfully"
        cgi_success

        # Remove the zone + pref-1990 rules after the response: the fw4 reload
        # must never run inside the request.
        ( ( sleep 1; ts_net_teardown ) </dev/null >/dev/null 2>&1 & )
        exit 0
    fi

    # Unknown action
    cgi_error "unknown_action" "Unknown action: $ACTION"
    exit 0
fi

# Method not allowed
cgi_method_not_allowed
