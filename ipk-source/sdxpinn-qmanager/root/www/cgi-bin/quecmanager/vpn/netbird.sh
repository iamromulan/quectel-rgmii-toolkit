#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/netbird_firewall.sh
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh
# =============================================================================
# netbird.sh — CGI Endpoint: NetBird VPN Management (GET + POST)
# =============================================================================
# GET:  Returns installation status, daemon state, connection info, and peers.
# POST: Connect/disconnect, start/stop daemon, enable/disable on boot.
#
# NetBird manages its own config — we are a thin control layer.
# No UCI config needed.
#
# Data sources:
#   netbird status -d     -> connection state, self info, peers
#   netbird version       -> installed version
#   /etc/init.d/netbird   -> daemon control (start/stop/enable/disable)
#
# POST body: { "action": "connect"|"disconnect"|"start_service"|
#                         "stop_service"|"set_boot_enabled"|... }
#
# Endpoint: GET/POST /cgi-bin/quecmanager/vpn/netbird.sh
# Install location: /www/cgi-bin/quecmanager/vpn/netbird.sh
# =============================================================================

qlog_init "cgi_netbird"
cgi_headers
cgi_handle_options

NB_INSTALL_RESULT="/tmp/qmanager_netbird_install.json"
# B5.11: root-only run dir, so a planted /tmp pidfile cannot fake "already running"
NB_INSTALL_PID="/var/run/qmanager/netbird_install.pid"

# --- Helper: check if netbird is installed -----------------------------------
is_installed() {
    command -v netbird >/dev/null 2>&1
}

# --- Helper: check if netbird daemon is running ------------------------------
is_daemon_running() {
    if [ -x /etc/init.d/netbird ]; then
        /etc/init.d/netbird running >/dev/null 2>&1 && return 0
    fi
    pidof netbird >/dev/null 2>&1
}

# --- Helper: check if netbird is enabled on boot ----------------------------
get_boot_enabled() {
    if [ -x /etc/init.d/netbird ]; then
        /etc/init.d/netbird enabled && echo "true" || echo "false"
    else
        echo "false"
    fi
}

# --- Helper: get netbird version string --------------------------------------
get_nb_version() {
    netbird version 2>/dev/null | head -1 | awk '{print $1}'
}

# --- Helper: parse 'netbird status' into JSON --------------------------------
# NetBird outputs structured text. Tries -d (detailed) first for per-peer info,
# falls back to basic output (which only has peer count, no details).
# Parses header fields and optional peer details with awk, emits JSON.
parse_netbird_status() {
    local raw

    # Try detailed output first (-d flag, available in newer versions)
    if command -v timeout >/dev/null 2>&1; then
        raw=$(timeout 5 netbird status -d 2>/dev/null)
    else
        raw=$(netbird status -d 2>/dev/null)
    fi

    # Fall back to basic status if -d failed or returned empty
    if [ -z "$raw" ]; then
        if command -v timeout >/dev/null 2>&1; then
            raw=$(timeout 5 netbird status 2>/dev/null)
        else
            raw=$(netbird status 2>/dev/null)
        fi
    fi

    if [ -z "$raw" ]; then
        echo '{}'
        return 1
    fi

    printf '%s\n' "$raw" | awk '
    BEGIN {
        management = "Unknown"
        signal = "Unknown"
        fqdn = ""
        nb_ip = ""
        iface_type = ""
        peers_connected = 0
        peers_total = 0
        in_peers = 0
        peer_count = 0
        # Current peer fields
        p_hostname = ""
        p_ip = ""
        p_status = ""
        p_conn_type = ""
        p_direct = ""
        p_last_seen = ""
        p_transfer_rx = ""
        p_transfer_tx = ""
    }

    # Flush current peer to array
    function flush_peer() {
        if (p_hostname == "") return
        if (peer_count > 0) peers = peers ","
        gsub(/"/, "\\\"", p_hostname)
        gsub(/"/, "\\\"", p_ip)
        gsub(/"/, "\\\"", p_status)
        gsub(/"/, "\\\"", p_conn_type)
        gsub(/"/, "\\\"", p_direct)
        gsub(/"/, "\\\"", p_last_seen)
        gsub(/"/, "\\\"", p_transfer_rx)
        gsub(/"/, "\\\"", p_transfer_tx)
        peers = peers "{"
        peers = peers "\"hostname\":\"" p_hostname "\","
        peers = peers "\"netbird_ip\":\"" p_ip "\","
        peers = peers "\"status\":\"" p_status "\","
        peers = peers "\"connection_type\":\"" p_conn_type "\","
        peers = peers "\"direct\":\"" p_direct "\","
        peers = peers "\"last_seen\":\"" p_last_seen "\","
        peers = peers "\"transfer_received\":\"" p_transfer_rx "\","
        peers = peers "\"transfer_sent\":\"" p_transfer_tx "\""
        peers = peers "}"
        peer_count++
        p_hostname = ""; p_ip = ""; p_status = ""
        p_conn_type = ""; p_direct = ""; p_last_seen = ""
        p_transfer_rx = ""; p_transfer_tx = ""
    }

    # Skip version lines anywhere in output
    /^Daemon version:/ { next }
    /^CLI version:/ { next }
    /^-- detail --/ { next }
    /^[[:space:]]+Public key:/ { next }
    /^[[:space:]]+ICE candidate/ { next }

    # --- Header fields (can appear BEFORE or AFTER peers section) ---
    # Management: "Connected" or "Connected to https://..."
    /^Management:/ {
        sub(/^Management:[[:space:]]*/, "")
        # Extract just "Connected" from "Connected to https://..."
        if ($0 ~ /^Connected/) management = "Connected"
        else management = $0
        next
    }
    /^Signal:/ {
        sub(/^Signal:[[:space:]]*/, "")
        if ($0 ~ /^Connected/) signal = "Connected"
        else signal = $0
        next
    }
    /^FQDN:/ {
        sub(/^FQDN:[[:space:]]*/, "")
        fqdn = $0
        next
    }
    /^NetBird IP:/ {
        sub(/^NetBird IP:[[:space:]]*/, "")
        nb_ip = $0
        next
    }
    /^Interface type:/ {
        sub(/^Interface type:[[:space:]]*/, "")
        iface_type = $0
        next
    }
    /^Peers count:/ {
        sub(/^Peers count:[[:space:]]*/, "")
        # Format: "1/1 Connected" or "0/2 Connected"
        split($0, pc, "/")
        peers_connected = pc[1] + 0
        peers_total = pc[2] + 0
        next
    }

    # --- Transition to peers section ---
    /^Peers detail:/ || /^NetBird Peers/ {
        in_peers = 1
        next
    }

    # Leaving peers section when we hit a non-indented header line
    in_peers && /^[A-Z][a-z].*:/ && !/^[[:space:]]/ {
        flush_peer()
        in_peers = 0
        # Re-process this line as a header field
        if (/^Management:/) {
            sub(/^Management:[[:space:]]*/, "")
            if ($0 ~ /^Connected/) management = "Connected"
            else management = $0
            next
        }
        if (/^Signal:/) {
            sub(/^Signal:[[:space:]]*/, "")
            if ($0 ~ /^Connected/) signal = "Connected"
            else signal = $0
            next
        }
        if (/^FQDN:/) { sub(/^FQDN:[[:space:]]*/, ""); fqdn = $0; next }
        if (/^NetBird IP:/) { sub(/^NetBird IP:[[:space:]]*/, ""); nb_ip = $0; next }
        if (/^Interface type:/) { sub(/^Interface type:[[:space:]]*/, ""); iface_type = $0; next }
        if (/^Peers count:/) {
            sub(/^Peers count:[[:space:]]*/, "")
            split($0, pc, "/"); peers_connected = pc[1] + 0; peers_total = pc[2] + 0
            next
        }
    }

    # --- Peer parsing (indented lines within peers section) ---
    # Hostname line: " hostname:" (indented, ends with colon)
    in_peers && /^[[:space:]]+[[:alnum:]]/ && /:$/ {
        flush_peer()
        p_hostname = $0
        sub(/^[[:space:]]*/, "", p_hostname)
        sub(/:$/, "", p_hostname)
        next
    }

    in_peers && /^[[:space:]]+NetBird IP:/ {
        sub(/^[[:space:]]*NetBird IP:[[:space:]]*/, "")
        p_ip = $0
        next
    }
    in_peers && /^[[:space:]]+Status:/ {
        sub(/^[[:space:]]*Status:[[:space:]]*/, "")
        p_status = $0
        next
    }
    in_peers && /^[[:space:]]+Connection type:/ {
        sub(/^[[:space:]]*Connection type:[[:space:]]*/, "")
        p_conn_type = $0
        next
    }
    in_peers && /^[[:space:]]+Direct:/ {
        sub(/^[[:space:]]*Direct:[[:space:]]*/, "")
        p_direct = $0
        next
    }
    in_peers && /^[[:space:]]+Last connection update:/ {
        sub(/^[[:space:]]*Last connection update:[[:space:]]*/, "")
        p_last_seen = $0
        next
    }
    in_peers && /^[[:space:]]+(Last|Last WireGuard) [Hh]andshake:/ {
        sub(/^[[:space:]]*Last[^:]*:[[:space:]]*/, "")
        p_last_seen = $0
        next
    }
    in_peers && /^[[:space:]]+Transfer status/ {
        sub(/^.*:[[:space:]]*/, "")
        split($0, tr, "/")
        if (length(tr) >= 2) {
            p_transfer_rx = tr[1]
            p_transfer_tx = tr[2]
        }
        next
    }

    END {
        flush_peer()
        gsub(/"/, "\\\"", management)
        gsub(/"/, "\\\"", signal)
        gsub(/"/, "\\\"", fqdn)
        gsub(/"/, "\\\"", nb_ip)
        gsub(/"/, "\\\"", iface_type)

        printf "{"
        printf "\"management\":\"%s\",", management
        printf "\"signal\":\"%s\",", signal
        printf "\"fqdn\":\"%s\",", fqdn
        printf "\"netbird_ip\":\"%s\",", nb_ip
        printf "\"interface_type\":\"%s\",", iface_type
        printf "\"peers_connected\":%d,", peers_connected
        printf "\"peers_total\":%d,", peers_total
        printf "\"peers\":[%s]", peers
        printf "}"
    }
    '
}

# =============================================================================
# GET — Fetch installation status, daemon state, connection info, peers
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then

    if command -v tailscale >/dev/null 2>&1; then
        other_vpn_installed="true"
    else
        other_vpn_installed="false"
    fi

    # --- Tier 1: Not installed -----------------------------------------------
    if ! is_installed; then
        qlog_info "NetBird not installed"
        jq -n \
            --argjson other_vpn_installed "$other_vpn_installed" \
            '{
                success: true,
                installed: false,
                install_hint: "opkg update && opkg install netbird",
                other_vpn_installed: $other_vpn_installed,
                other_vpn_name: "Tailscale"
            }'
        exit 0
    fi

    nb_version=$(get_nb_version)
    boot_enabled=$(get_boot_enabled)

    # --- Tier 2: Installed but daemon not running ----------------------------
    if ! is_daemon_running; then
        qlog_info "NetBird installed but daemon not running"
        jq -n \
            --argjson installed true \
            --argjson daemon_running false \
            --argjson enabled_on_boot "$boot_enabled" \
            --arg version "$nb_version" \
            --argjson other_vpn_installed "$other_vpn_installed" \
            '{
                success: true,
                installed: $installed,
                daemon_running: $daemon_running,
                enabled_on_boot: $enabled_on_boot,
                version: $version,
                other_vpn_installed: $other_vpn_installed,
                other_vpn_name: "Tailscale"
            }'
        exit 0
    fi

    # --- Tier 3: Daemon running — fetch full status --------------------------
    qlog_info "Fetching netbird status"

    status_json=$(parse_netbird_status)

    if [ -z "$status_json" ] || ! printf '%s' "$status_json" | jq -e . >/dev/null 2>&1; then
        qlog_error "Failed to parse netbird status"
        jq -n \
            --argjson installed true \
            --argjson daemon_running true \
            --argjson enabled_on_boot "$boot_enabled" \
            --arg version "$nb_version" \
            --argjson other_vpn_installed "$other_vpn_installed" \
            '{
                success: true,
                installed: $installed,
                daemon_running: $daemon_running,
                enabled_on_boot: $enabled_on_boot,
                version: $version,
                error_detail: "Could not retrieve status from netbird daemon",
                other_vpn_installed: $other_vpn_installed,
                other_vpn_name: "Tailscale"
            }'
        exit 0
    fi

    # Extract fields from parsed status
    management=$(printf '%s' "$status_json" | jq -r '.management // "Unknown"')
    signal=$(printf '%s' "$status_json" | jq -r '.signal // "Unknown"')
    fqdn=$(printf '%s' "$status_json" | jq -r '.fqdn // ""')
    netbird_ip=$(printf '%s' "$status_json" | jq -r '.netbird_ip // ""')
    iface_type=$(printf '%s' "$status_json" | jq -r '.interface_type // ""')
    peers_connected=$(printf '%s' "$status_json" | jq -r '.peers_connected // 0')
    peers_total=$(printf '%s' "$status_json" | jq -r '.peers_total // 0')
    peers_array=$(printf '%s' "$status_json" | jq '.peers // []')

    # Determine connected state from management + signal
    if [ "$management" = "Connected" ] && [ "$signal" = "Connected" ]; then
        backend_state="Connected"
    elif [ "$management" = "Connected" ]; then
        backend_state="Connecting"
    else
        backend_state="Disconnected"
    fi

    # Assemble full response
    jq -n \
        --argjson installed true \
        --argjson daemon_running true \
        --argjson enabled_on_boot "$boot_enabled" \
        --arg version "$nb_version" \
        --arg backend_state "$backend_state" \
        --arg management "$management" \
        --arg signal "$signal" \
        --arg fqdn "$fqdn" \
        --arg netbird_ip "$netbird_ip" \
        --arg interface_type "$iface_type" \
        --argjson peers_connected "$peers_connected" \
        --argjson peers_total "$peers_total" \
        --argjson peers "$peers_array" \
        --argjson other_vpn_installed "$other_vpn_installed" \
        '{
            success: true,
            installed: $installed,
            daemon_running: $daemon_running,
            enabled_on_boot: $enabled_on_boot,
            version: $version,
            backend_state: $backend_state,
            management: $management,
            signal: $signal,
            fqdn: $fqdn,
            netbird_ip: $netbird_ip,
            interface_type: $interface_type,
            peers_connected: $peers_connected,
            peers_total: $peers_total,
            peers: $peers,
            other_vpn_installed: $other_vpn_installed,
            other_vpn_name: "Tailscale"
        }'
    exit 0
fi

# =============================================================================
# POST — Actions: connect, disconnect, start/stop service, boot toggle
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty')

    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: install — install netbird via opkg (background)
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "install" ]; then

        # Mutual exclusion: refuse if other VPN is installed
        if command -v tailscale >/dev/null 2>&1; then
            cgi_error "other_vpn_installed" "Tailscale is already installed. Uninstall it before installing NetBird."
            exit 0
        fi

        # Check if already running
        if ! command -v qm_read_pid >/dev/null 2>&1 || ! qm_run_dir >/dev/null; then
            cgi_error "install_failed" "Cannot prepare the install state directory"
            exit 0
        fi
        if qm_read_pid "$NB_INSTALL_PID" netbird.sh >/dev/null; then
            cgi_error "already_running" "Installation already in progress"
            exit 0
        fi

        # Already installed?
        if is_installed; then
            cgi_error "already_installed" "NetBird is already installed"
            exit 0
        fi

        qlog_info "Starting NetBird installation via opkg"

        # Spawn background installer
        (
            # $$ is the CGI's pid here; record this subshell's own pid
            qm_self_pid && printf '%s\n' "$QM_SELF_PID" | qm_atomic_write "$NB_INSTALL_PID"
            trap 'rm -f "$NB_INSTALL_PID"' EXIT

            printf '{"success":true,"status":"running","message":"Updating package lists..."}' > "$NB_INSTALL_RESULT"
            if ! opkg update >/dev/null 2>&1; then
                printf '{"success":false,"status":"error","message":"Failed to update package lists","detail":"Check internet connection and opkg feeds"}' > "$NB_INSTALL_RESULT"
                exit 1
            fi

            printf '{"success":true,"status":"running","message":"Installing netbird..."}' > "$NB_INSTALL_RESULT"
            if ! opkg install netbird >/dev/null 2>&1; then
                printf '{"success":false,"status":"error","message":"opkg install failed","detail":"Package may not be available for this architecture"}' > "$NB_INSTALL_RESULT"
                exit 1
            fi

            # Verify
            if command -v netbird >/dev/null 2>&1; then
                netbird_fw_ensure_zone "netbird" "wt0"
                printf '{"success":true,"status":"complete","message":"NetBird installed successfully"}' > "$NB_INSTALL_RESULT"
            else
                printf '{"success":false,"status":"error","message":"Package installed but binary not found"}' > "$NB_INSTALL_RESULT"
            fi
        ) </dev/null >/dev/null 2>&1 &

        cgi_success
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: install_status — poll install progress
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "install_status" ]; then
        if [ -f "$NB_INSTALL_RESULT" ]; then
            cat "$NB_INSTALL_RESULT"
        else
            printf '{"success":true,"status":"idle"}'
        fi
        exit 0
    fi

    # All remaining POST actions require netbird to be installed
    if ! is_installed; then
        cgi_error "not_installed" "NetBird is not installed"
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: connect — netbird up (with optional setup key)
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "connect" ]; then
        qlog_info "Connecting to NetBird"

        # Ensure daemon is running first
        if ! is_daemon_running; then
            if [ -x /etc/init.d/netbird ]; then
                /etc/init.d/netbird start >/dev/null 2>&1
            else
                netbird service start >/dev/null 2>&1
            fi
            # Wait for daemon to be ready (up to 5 seconds)
            attempts=0
            while [ "$attempts" -lt 5 ]; do
                sleep 1
                is_daemon_running && break
                attempts=$((attempts + 1))
            done
            if ! is_daemon_running; then
                cgi_error "daemon_start_failed" "Could not start netbird daemon"
                exit 0
            fi
        fi

        # Extract optional setup key
        setup_key=$(printf '%s' "$POST_DATA" | jq -r '.setup_key // empty')

        if [ -n "$setup_key" ]; then
            result=$(netbird up --setup-key "$setup_key" 2>&1)
        else
            result=$(netbird up 2>&1)
        fi
        rc=$?

        if [ "$rc" -ne 0 ]; then
            qlog_error "netbird up failed: $result"
            cgi_error "connect_failed" "Failed to connect: $result"
            exit 0
        fi

        qlog_info "NetBird connected"
        cgi_success
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: disconnect — netbird down
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "disconnect" ]; then
        qlog_info "Disconnecting NetBird"
        result=$(netbird down 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            qlog_error "netbird down failed: $result"
            cgi_error "disconnect_failed" "Failed to disconnect: $result"
            exit 0
        fi
        qlog_info "NetBird disconnected"
        cgi_success
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: start_service — start netbird daemon
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "start_service" ]; then
        if is_daemon_running; then
            cgi_error "already_running" "NetBird daemon is already running"
            exit 0
        fi
        qlog_info "Starting netbird daemon"
        if [ -x /etc/init.d/netbird ]; then
            /etc/init.d/netbird start >/dev/null 2>&1
        else
            netbird service start >/dev/null 2>&1
        fi
        sleep 1
        if is_daemon_running; then
            qlog_info "NetBird daemon started"
            cgi_success
        else
            cgi_error "start_failed" "Failed to start netbird daemon"
        fi
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: stop_service — stop netbird daemon
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "stop_service" ]; then
        qlog_info "Stopping netbird daemon"
        if [ -x /etc/init.d/netbird ]; then
            /etc/init.d/netbird stop >/dev/null 2>&1
        else
            netbird service stop >/dev/null 2>&1
        fi
        qlog_info "NetBird daemon stopped"
        cgi_success
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: set_boot_enabled — enable/disable netbird on boot
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "set_boot_enabled" ]; then
        boot_enabled=$(printf '%s' "$POST_DATA" | jq -r '.enabled | if . == null then empty else tostring end')
        if [ -z "$boot_enabled" ]; then
            cgi_error "missing_field" "enabled field is required"
            exit 0
        fi
        if [ ! -x /etc/init.d/netbird ]; then
            cgi_error "no_init_script" "NetBird init script not found"
            exit 0
        fi
        case "$boot_enabled" in
            true)
                /etc/init.d/netbird enable >/dev/null 2>&1
                qlog_info "NetBird enabled on boot"
                ;;
            false)
                /etc/init.d/netbird disable >/dev/null 2>&1
                qlog_info "NetBird disabled on boot"
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
    # action: uninstall — remove netbird from the device
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "uninstall" ]; then
        qlog_info "Uninstalling NetBird"

        # Stop service if running
        if is_daemon_running; then
            qlog_info "Stopping NetBird daemon before uninstall"
            netbird down >/dev/null 2>&1
            if [ -x /etc/init.d/netbird ]; then
                /etc/init.d/netbird stop >/dev/null 2>&1
            else
                netbird service stop >/dev/null 2>&1
            fi
            sleep 1
        fi

        # Disable boot entry if init script exists
        [ -x /etc/init.d/netbird ] && /etc/init.d/netbird disable >/dev/null 2>&1

        # Remove packages
        opkg remove netbird >/dev/null 2>&1

        # Clean up state files
        rm -rf /var/lib/netbird/
        rm -f /tmp/qmanager_netbird_install.json "$NB_INSTALL_PID"

        # Verify removal (check actual binary paths, not command -v which can be cached)
        hash -r 2>/dev/null
        if [ -x /usr/sbin/netbird ] || [ -x /usr/bin/netbird ]; then
            qlog_error "NetBird binary still present after opkg remove"
            cgi_error "uninstall_failed" "Failed to remove NetBird"
            exit 0
        fi

        qlog_info "NetBird uninstalled successfully"
        cgi_success

        # Remove firewall zone in background AFTER response is sent.
        # netbird_fw_remove_zone restarts the firewall which kills the HTTP
        # connection — doing it after cgi_success ensures the frontend
        # receives a clean JSON response.
        ( netbird_fw_remove_zone "netbird" ) </dev/null >/dev/null 2>&1 &
        exit 0
    fi

    # Unknown action
    cgi_error "unknown_action" "Unknown action: $ACTION"
    exit 0
fi

# Method not allowed
cgi_method_not_allowed
