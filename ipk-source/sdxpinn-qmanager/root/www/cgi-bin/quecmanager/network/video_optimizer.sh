#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/dpi_helper.sh
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

qlog_init "cgi_video_optimizer"
cgi_headers
cgi_handle_options

DPI_VERIFY_RESULT="/tmp/qmanager_dpi_verify.json"
# B5.11: pidfiles in the root-only run dir (a planted /tmp pidfile could fake
# "running" forever); qmanager_dpi_install writes the same install path.
DPI_VERIFY_PID="/var/run/qmanager/dpi_verify.pid"
DPI_INSTALL_RESULT="/tmp/qmanager_dpi_install.json"
DPI_INSTALL_PID="/var/run/qmanager/dpi_install.pid"

# dpi_spawn_guard PIDFILE CMDLINE — exit with the envelope when the worker is
# already running or its state dir cannot be made trustworthy.
dpi_spawn_guard() {
    if ! command -v qm_read_pid >/dev/null 2>&1 || ! qm_run_dir >/dev/null; then
        cgi_error "state_dir_failed" "Cannot prepare the DPI state directory"
        exit 0
    fi
    if qm_read_pid "$1" "$2" >/dev/null; then
        printf '{"success":true,"status":"running"}'
        exit 0
    fi
}

# Ensure UCI section exists with defaults
ensure_dpi_config() {
    local section existing_repeats
    section=$(uci -q get quecmanager.video_optimizer)
    if [ -z "$section" ]; then
        uci set quecmanager.video_optimizer=video_optimizer
        uci set quecmanager.video_optimizer.enabled='0'
        uci set quecmanager.video_optimizer.quic_enabled='1'
        uci set quecmanager.video_optimizer.desync_repeats='1'
        uci commit quecmanager
        return
    fi

    # Backfill desync_repeats for installs created before this key existed
    existing_repeats=$(uci -q get quecmanager.video_optimizer.desync_repeats)
    if [ -z "$existing_repeats" ]; then
        uci set quecmanager.video_optimizer.desync_repeats='1'
        uci commit quecmanager
    fi
}

ensure_masq_config() {
    local section
    section=$(uci -q get quecmanager.traffic_masquerade)
    if [ -z "$section" ]; then
        uci set quecmanager.traffic_masquerade=traffic_masquerade
        uci set quecmanager.traffic_masquerade.enabled='0'
        uci set quecmanager.traffic_masquerade.sni_domain='speedtest.net'
        uci commit quecmanager
    fi
}

ensure_dpi_config
ensure_masq_config

case "$REQUEST_METHOD" in
GET)
    # Check for verify_status action
    action=$(echo "$QUERY_STRING" | sed -n 's/.*action=\([^&]*\).*/\1/p')

    if [ "$action" = "verify_status" ]; then
        # Return verification test results
        if [ -f "$DPI_VERIFY_RESULT" ]; then
            cat "$DPI_VERIFY_RESULT"
        else
            printf '{"success":true,"status":"idle"}'
        fi
        exit 0
    fi

    if [ "$action" = "install_status" ]; then
        # Return install progress
        if [ -f "$DPI_INSTALL_RESULT" ]; then
            cat "$DPI_INSTALL_RESULT"
        else
            printf '{"success":true,"status":"idle"}'
        fi
        exit 0
    fi

    # --- Hostlist section ---
    section=$(echo "$QUERY_STRING" | sed -n 's/.*section=\([^&]*\).*/\1/p')
    if [ "$section" = "hostlist" ]; then
        if [ -f "$DPI_HOSTLIST" ]; then
            domains=$(grep -v '^[[:space:]]*#' "$DPI_HOSTLIST" | grep -v '^[[:space:]]*$' | jq -R . | jq -s .)
        else
            domains='[]'
        fi
        if [ -f "$DPI_HOSTLIST_DEFAULT" ]; then
            default_domains=$(grep -v '^[[:space:]]*#' "$DPI_HOSTLIST_DEFAULT" | grep -v '^[[:space:]]*$' | jq -R . | jq -s .)
        else
            default_domains='[]'
        fi
        count=$(echo "$domains" | jq 'length')
        jq -n --argjson domains "$domains" --argjson default_domains "$default_domains" --argjson count "$count" \
            '{"success":true,"domains":$domains,"default_domains":$default_domains,"count":$count}'
        exit 0
    fi

    # --- Traffic Masquerade section ---
    if [ "$section" = "masquerade" ]; then
        masq_enabled=$(uci -q get quecmanager.traffic_masquerade.enabled)
        vo_enabled=$(uci -q get quecmanager.video_optimizer.enabled)
        sni_domain=$(uci -q get quecmanager.traffic_masquerade.sni_domain)
        # Only report live stats when masquerade is the active mode —
        # VO and masq share a single nfqws process/PID/counters
        if [ "$masq_enabled" = "1" ]; then
            masq_status=$(dpi_get_status)
            masq_uptime=$(dpi_get_uptime)
            masq_packets=$(dpi_get_packet_count)
        else
            masq_status="stopped"
            masq_uptime="0s"
            masq_packets=0
        fi
        dpi_check_binary && binary_ok="true" || binary_ok="false"
        dpi_check_kmod && kmod_ok="true" || kmod_ok="false"

        jq -n \
            --argjson success true \
            --arg enabled "${masq_enabled:-0}" \
            --arg vo_enabled "${vo_enabled:-0}" \
            --arg status "$masq_status" \
            --arg uptime "$masq_uptime" \
            --argjson packets_processed "${masq_packets:-0}" \
            --arg sni_domain "${sni_domain:-speedtest.net}" \
            --argjson binary_installed "$binary_ok" \
            --argjson kernel_module_loaded "$kmod_ok" \
            '{
                success: $success,
                enabled: ($enabled == "1"),
                other_enabled: ($vo_enabled == "1"),
                status: $status,
                uptime: $uptime,
                packets_processed: $packets_processed,
                sni_domain: $sni_domain,
                binary_installed: $binary_installed,
                kernel_module_loaded: $kernel_module_loaded
            }'
        exit 0
    fi

    # Read UCI settings
    enabled=$(uci -q get quecmanager.video_optimizer.enabled)
    masq_enabled=$(uci -q get quecmanager.traffic_masquerade.enabled)
    desync_repeats=$(uci -q get quecmanager.video_optimizer.desync_repeats)
    case "$desync_repeats" in
        ''|*[!0-9]*) desync_repeats=1 ;;
        *)
            if [ "$desync_repeats" -lt 1 ] || [ "$desync_repeats" -gt 10 ]; then
                desync_repeats=1
            fi
            ;;
    esac

    # Only report live stats when video optimizer is the active mode —
    # VO and masq share a single nfqws process/PID/counters
    if [ "$enabled" = "1" ]; then
        status=$(dpi_get_status)
        uptime=$(dpi_get_uptime)
        packets=$(dpi_get_packet_count)
    else
        status="stopped"
        uptime="0s"
        packets=0
    fi
    domains=$(dpi_get_domain_count)
    dpi_check_binary && binary_ok="true" || binary_ok="false"
    dpi_check_kmod && kmod_ok="true" || kmod_ok="false"

    # Build response
    jq -n \
        --argjson success true \
        --arg enabled "${enabled:-0}" \
        --arg masq_enabled "${masq_enabled:-0}" \
        --arg status "$status" \
        --arg uptime "$uptime" \
        --argjson packets_processed "${packets:-0}" \
        --argjson domains_loaded "${domains:-0}" \
        --argjson desync_repeats "$desync_repeats" \
        --argjson binary_installed "$binary_ok" \
        --argjson kernel_module_loaded "$kmod_ok" \
        '{
            success: $success,
            enabled: ($enabled == "1"),
            other_enabled: ($masq_enabled == "1"),
            status: $status,
            uptime: $uptime,
            packets_processed: $packets_processed,
            domains_loaded: $domains_loaded,
            desync_repeats: $desync_repeats,
            binary_installed: $binary_installed,
            kernel_module_loaded: $kernel_module_loaded
        }'
    ;;

POST)
    cgi_read_post
    action=$(echo "$POST_DATA" | jq -r '.action // empty')

    case "$action" in
    save)
        # Extract enabled field
        new_enabled=$(echo "$POST_DATA" | jq -r '(.enabled) | if . == null then empty else tostring end')

        if [ -z "$new_enabled" ]; then
            cgi_error "missing_field" "enabled field is required"
            exit 0
        fi

        # Optional: desync_repeats (integer 1-10). Absence = no change.
        new_repeats=$(echo "$POST_DATA" | jq -r '(.desync_repeats) | if . == null then empty else tostring end')
        if [ -n "$new_repeats" ]; then
            case "$new_repeats" in
                ''|*[!0-9]*)
                    cgi_error "invalid_repeats" "desync_repeats must be an integer between 1 and 10"
                    exit 0
                    ;;
                *)
                    if [ "$new_repeats" -lt 1 ] || [ "$new_repeats" -gt 10 ]; then
                        cgi_error "invalid_repeats" "desync_repeats must be an integer between 1 and 10"
                        exit 0
                    fi
                    ;;
            esac
            uci set quecmanager.video_optimizer.desync_repeats="$new_repeats"
        fi

        # Map to UCI value — enforce mutual exclusion with masquerade
        if [ "$new_enabled" = "true" ]; then
            uci set quecmanager.traffic_masquerade.enabled='0'
            uci set quecmanager.video_optimizer.enabled='1'
        else
            uci set quecmanager.video_optimizer.enabled='0'
        fi
        uci commit quecmanager

        # Restart or stop service + manage boot persistence
        if [ "$new_enabled" = "true" ]; then
            /etc/init.d/qmanager_dpi enable 2>/dev/null
            /etc/init.d/qmanager_dpi restart
            qlog_info "Video Optimizer enabled (boot: on)"
        else
            /etc/init.d/qmanager_dpi stop
            # Disable boot if masquerade is also off
            masq_check=$(uci -q get quecmanager.traffic_masquerade.enabled)
            [ "$masq_check" != "1" ] && /etc/init.d/qmanager_dpi disable 2>/dev/null
            qlog_info "Video Optimizer disabled"
        fi

        cgi_success
        ;;

    verify)
        # Check if verification is already running
        dpi_spawn_guard "$DPI_VERIFY_PID" qmanager_dpi_verify

        # Clear old results
        rm -f "$DPI_VERIFY_RESULT"

        # Spawn background verification
        /usr/bin/qmanager_dpi_verify </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" | qm_atomic_write "$DPI_VERIFY_PID"

        qlog_info "Verification test started"
        printf '{"success":true,"status":"started"}'
        ;;

    install)
        # Check if install is already running
        dpi_spawn_guard "$DPI_INSTALL_PID" qmanager_dpi_install

        # Clear old results
        rm -f "$DPI_INSTALL_RESULT"

        # Spawn background installer
        /usr/bin/qmanager_dpi_install </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" | qm_atomic_write "$DPI_INSTALL_PID"

        qlog_info "nfqws installation started"
        printf '{"success":true,"status":"started"}'
        ;;

    test_masquerade)
        # Quick injection test: read counter, make HTTPS request, read counter again
        # Must verify masquerade specifically is enabled — VO shares the same process
        masq_test_enabled=$(uci -q get quecmanager.traffic_masquerade.enabled)
        if [ "$masq_test_enabled" != "1" ] || [ "$(dpi_get_status)" != "running" ]; then
            printf '{"success":false,"error":"Traffic Masquerade is not running. Enable it first."}'
            exit 0
        fi

        count_before=$(dpi_get_packet_count)
        curl -4 -so /dev/null --max-time 5 "https://speed.cloudflare.com/__down?bytes=1000" 2>/dev/null
        sleep 1
        count_after=$(dpi_get_packet_count)

        injected=$((count_after - count_before))
        if [ "$injected" -gt 0 ]; then
            printf '{"success":true,"injected":true,"packets":%d,"message":"Fake SNI injection confirmed (%d packets processed)"}' "$injected" "$injected"
        else
            printf '{"success":true,"injected":false,"packets":0,"message":"No packets intercepted. The cellular interface may have changed. Try restarting the service."}'
        fi
        ;;

    save_masquerade)
        new_enabled=$(echo "$POST_DATA" | jq -r '(.enabled) | if . == null then empty else tostring end')
        new_sni=$(echo "$POST_DATA" | jq -r '(.sni_domain) | if . == null then empty else . end')

        if [ -z "$new_enabled" ]; then
            cgi_error "missing_field" "enabled field is required"
            exit 0
        fi

        # Validate SNI domain (alphanumeric, dots, hyphens, must contain a dot)
        if [ -n "$new_sni" ]; then
            if ! echo "$new_sni" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$'; then
                cgi_error "invalid_domain" "Invalid domain format"
                exit 0
            fi
            if ! echo "$new_sni" | grep -q '\.'; then
                cgi_error "invalid_domain" "Domain must contain at least one dot"
                exit 0
            fi
            if [ "${#new_sni}" -gt 253 ]; then
                cgi_error "invalid_domain" "Domain name too long (max 253 chars)"
                exit 0
            fi
            uci set quecmanager.traffic_masquerade.sni_domain="$new_sni"
        fi

        # Enforce mutual exclusion with video optimizer
        if [ "$new_enabled" = "true" ]; then
            uci set quecmanager.video_optimizer.enabled='0'
            uci set quecmanager.traffic_masquerade.enabled='1'
        else
            uci set quecmanager.traffic_masquerade.enabled='0'
        fi
        uci commit quecmanager

        # Restart or stop service + manage boot persistence
        if [ "$new_enabled" = "true" ]; then
            /etc/init.d/qmanager_dpi enable 2>/dev/null
            /etc/init.d/qmanager_dpi restart
            qlog_info "Traffic Masquerade enabled (sni=$new_sni, boot: on)"
        else
            /etc/init.d/qmanager_dpi stop
            # Disable boot if video optimizer is also off
            vo_check=$(uci -q get quecmanager.video_optimizer.enabled)
            [ "$vo_check" != "1" ] && /etc/init.d/qmanager_dpi disable 2>/dev/null
            qlog_info "Traffic Masquerade disabled"
        fi

        cgi_success
        ;;

    save_hostlist)
        domains=$(echo "$POST_DATA" | jq -r '.domains // empty')
        if [ -z "$domains" ] || [ "$domains" = "null" ]; then
            cgi_error "missing_field" "domains array is required"
            exit 0
        fi

        # Validate all domains upfront using jq (avoids subshell exit issue)
        bad_domain=$(echo "$POST_DATA" | jq -r '.domains[]' | while IFS= read -r d; do
            if ! echo "$d" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$'; then
                echo "$d"; break
            fi
            if ! echo "$d" | grep -q '\.'; then
                echo "$d"; break
            fi
        done)
        if [ -n "$bad_domain" ]; then
            cgi_error "invalid_domain" "Invalid domain: $bad_domain"
            exit 0
        fi

        # Atomic write: temp file + mv
        tmp_file="${DPI_HOSTLIST}.tmp.$$"
        echo "$POST_DATA" | jq -r '.domains[]' > "$tmp_file"
        mv "$tmp_file" "$DPI_HOSTLIST"

        # Restart service if VO is currently running to pick up new list
        vo_enabled=$(uci -q get quecmanager.video_optimizer.enabled)
        if [ "$vo_enabled" = "1" ] && [ "$(dpi_get_status)" = "running" ]; then
            /etc/init.d/qmanager_dpi restart
            qlog_info "Hostlist updated, service restarted"
        else
            qlog_info "Hostlist updated"
        fi

        cgi_success
        ;;

    restore_hostlist)
        if [ ! -f "$DPI_HOSTLIST_DEFAULT" ]; then
            cgi_error "no_default" "Default hostname list not found"
            exit 0
        fi

        cp "$DPI_HOSTLIST_DEFAULT" "${DPI_HOSTLIST}.tmp.$$"
        mv "${DPI_HOSTLIST}.tmp.$$" "$DPI_HOSTLIST"

        vo_enabled=$(uci -q get quecmanager.video_optimizer.enabled)
        if [ "$vo_enabled" = "1" ] && [ "$(dpi_get_status)" = "running" ]; then
            /etc/init.d/qmanager_dpi restart
            qlog_info "Hostlist restored to default, service restarted"
        else
            qlog_info "Hostlist restored to default"
        fi

        cgi_success
        ;;

    uninstall)
        # Safety: refuse if nfqws service is running
        if [ "$(dpi_get_status)" = "running" ]; then
            cgi_error "service_running" "Disable the service before uninstalling"
            exit 0
        fi

        qlog_info "Uninstalling nfqws binary"

        # Stop service, disable boot, and clean up nftables rules
        [ -x /etc/init.d/qmanager_dpi ] && {
            /etc/init.d/qmanager_dpi stop >/dev/null 2>&1
            /etc/init.d/qmanager_dpi disable 2>/dev/null
        }

        # Disable both features in UCI
        uci -q set quecmanager.video_optimizer.enabled='0'
        uci -q set quecmanager.traffic_masquerade.enabled='0'
        uci commit quecmanager 2>/dev/null

        # Remove binary
        rm -f /usr/bin/nfqws

        # Verify removal
        if [ -x /usr/bin/nfqws ]; then
            qlog_error "nfqws binary still present after removal"
            cgi_error "uninstall_failed" "Failed to remove nfqws binary"
            exit 0
        fi

        qlog_info "nfqws uninstalled successfully"
        cgi_success
        ;;

    *)
        cgi_error "invalid_action" "Unknown action: $action"
        ;;
    esac
    ;;

*)
    cgi_method_not_allowed
    ;;
esac

exit 0
