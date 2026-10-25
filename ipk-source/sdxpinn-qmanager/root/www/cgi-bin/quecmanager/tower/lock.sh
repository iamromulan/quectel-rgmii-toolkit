#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# lock.sh — CGI Endpoint: Apply/Clear Tower Lock
# =============================================================================
# Handles tower lock and unlock operations for both LTE and NR-SA.
# On successful lock, updates config file and — ONLY if the user has
# already enabled Signal Failover via settings.sh — spawns the failover
# watcher. Locking does NOT auto-enable failover.
# On unlock, updates config and kills any running watcher, then disables
# failover in config when no other lock remains active.
#
# NOTE: Cell lock commands may disconnect the modem for 3-5 seconds
# before reconnecting. The failover watcher accounts for this with a
# 20-second settle delay.
#
# POST body examples:
#   LTE lock:   {"type":"lte","action":"lock","cells":[{"earfcn":1300,"pci":123},{"earfcn":1850,"pci":456}]}
#   LTE unlock: {"type":"lte","action":"unlock"}
#   NR-SA lock: {"type":"nr_sa","action":"lock","pci":901,"arfcn":504990,"scs":30,"band":41}
#   NR-SA unlock: {"type":"nr_sa","action":"unlock"}
#
# Endpoint: POST /cgi-bin/quecmanager/tower/lock.sh
# Install location: /www/cgi-bin/quecmanager/tower/lock.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_tower_lock"
cgi_headers
cgi_handle_options

# --- Load library ------------------------------------------------------------
if [ -f /usr/lib/qmanager/tower_lock_mgr.sh ]; then
    . /usr/lib/qmanager/tower_lock_mgr.sh
else
    cgi_error "internal_error" "tower lock library unavailable"
    exit 0
fi

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Read POST body ----------------------------------------------------------
cgi_read_post

# --- Parse common fields using jq --------------------------------------------
LOCK_TYPE=$(printf '%s' "$POST_DATA" | jq -r '.type // empty' 2>/dev/null)
ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty' 2>/dev/null)

if [ -z "$LOCK_TYPE" ]; then
    cgi_error "no_type" "Missing type field (lte or nr_sa)"
    exit 0
fi

if [ -z "$ACTION" ]; then
    cgi_error "no_action" "Missing action field (lock or unlock)"
    exit 0
fi

# --- Ensure config exists ----------------------------------------------------
tower_config_init

# =============================================================================
# LTE Lock/Unlock
# =============================================================================
if [ "$LOCK_TYPE" = "lte" ]; then

    if [ "$ACTION" = "lock" ]; then
        # --- Parse cells array from POST data using jq ---
        c1_earfcn=$(printf '%s' "$POST_DATA" | jq -r '(.cells[0].earfcn) | if . == null then empty else tostring end' 2>/dev/null)
        c1_pci=$(printf '%s' "$POST_DATA" | jq -r '(.cells[0].pci) | if . == null then empty else tostring end' 2>/dev/null)
        c2_earfcn=$(printf '%s' "$POST_DATA" | jq -r '(.cells[1].earfcn) | if . == null then empty else tostring end' 2>/dev/null)
        c2_pci=$(printf '%s' "$POST_DATA" | jq -r '(.cells[1].pci) | if . == null then empty else tostring end' 2>/dev/null)
        c3_earfcn=$(printf '%s' "$POST_DATA" | jq -r '(.cells[2].earfcn) | if . == null then empty else tostring end' 2>/dev/null)
        c3_pci=$(printf '%s' "$POST_DATA" | jq -r '(.cells[2].pci) | if . == null then empty else tostring end' 2>/dev/null)

        # Count valid cells
        num_cells=0
        at_args=""
        if [ -n "$c1_earfcn" ] && [ -n "$c1_pci" ]; then
            num_cells=$((num_cells + 1))
            at_args="$c1_earfcn $c1_pci"
        fi
        if [ -n "$c2_earfcn" ] && [ -n "$c2_pci" ]; then
            num_cells=$((num_cells + 1))
            at_args="$at_args $c2_earfcn $c2_pci"
        fi
        if [ -n "$c3_earfcn" ] && [ -n "$c3_pci" ]; then
            num_cells=$((num_cells + 1))
            at_args="$at_args $c3_earfcn $c3_pci"
        fi

        if [ "$num_cells" -eq 0 ]; then
            cgi_error "no_cells" "At least one EARFCN+PCI pair is required"
            exit 0
        fi

        # Validate ranges
        for val in $c1_earfcn $c2_earfcn $c3_earfcn; do
            [ -z "$val" ] && continue
            case "$val" in
                *[!0-9]*) cgi_error "invalid_earfcn" "EARFCN must be numeric"; exit 0 ;;
            esac
        done
        for val in $c1_pci $c2_pci $c3_pci; do
            [ -z "$val" ] && continue
            case "$val" in
                *[!0-9]*) cgi_error "invalid_pci" "PCI must be numeric"; exit 0 ;;
            esac
            if [ "$val" -gt 503 ]; then
                cgi_error "invalid_pci" "PCI must be 0-503"
                exit 0
            fi
        done

        qlog_info "LTE tower lock: $num_cells cell(s) — $at_args"

        # Send AT command
        result=$(tower_lock_lte "$num_cells" $at_args)
        rc=$?

        if [ $rc -ne 0 ] || [ -z "$result" ]; then
            qlog_error "LTE tower lock failed (rc=$rc)"
            cgi_error "modem_error" "Failed to send tower lock command"
            exit 0
        fi

        case "$result" in
            *ERROR*)
                qlog_error "LTE tower lock AT ERROR: $result"
                cgi_error "at_error" "Modem rejected tower lock command"
                exit 0
                ;;
        esac

        qlog_info "LTE tower lock applied successfully"

        # Re-apply custom MTU after interface bounce
        mtu_reapply_after_bounce

        # Update config file — preserve the user's current failover toggle.
        # Failover is no longer auto-enabled on lock; the user must toggle
        # Signal Failover explicitly via settings.sh.
        tower_config_update_lte "true" "$c1_earfcn" "$c1_pci" "$c2_earfcn" "$c2_pci" "$c3_earfcn" "$c3_pci"

        # Spawn failover watcher only if the user has failover enabled.
        # tower_spawn_failover_watcher returns "false" when config says off.
        failover_armed=$(tower_spawn_failover_watcher)

        jq -n --argjson nc "$num_cells" --argjson fa "$failover_armed" \
            '{"success":true,"type":"lte","action":"lock","num_cells":$nc,"failover_armed":$fa}'

    elif [ "$ACTION" = "unlock" ]; then
        # Kill failover watcher BEFORE sending unlock AT command.
        # During the 3-5s modem disconnect from unlock, the daemon could
        # misdetect "no signal" and clear ALL locks (including NR if active).
        fo_was_enabled=$(tower_config_get ".failover.enabled")
        tower_kill_failover_watcher
        rm -f "$TOWER_FAILOVER_FLAG"

        result=$(tower_unlock_lte)
        rc=$?

        if [ $rc -ne 0 ] || [ -z "$result" ]; then
            qlog_error "LTE tower unlock failed (rc=$rc)"
            cgi_error "modem_error" "Failed to clear tower lock"
            exit 0
        fi

        case "$result" in
            *ERROR*)
                qlog_error "LTE tower unlock AT ERROR: $result"
                cgi_error "at_error" "Modem rejected unlock command"
                exit 0
                ;;
        esac

        qlog_info "LTE tower lock cleared"

        # Re-apply custom MTU after interface bounce
        mtu_reapply_after_bounce

        # Update config — preserve ALL cell data, just set enabled=false
        tower_config_update '.lte.enabled = false'

        # Check if other lock remains active
        nr_active=$(tower_config_get ".nr_sa.enabled")
        if [ "$nr_active" = "true" ] && [ "$fo_was_enabled" = "true" ]; then
            # NR lock still active with failover — respawn watcher for it
            tower_spawn_failover_watcher >/dev/null
            qlog_info "NR lock still active — failover watcher respawned"
        else
            # No other lock — disable failover fully
            tower_config_update '.failover.enabled = false'
            /etc/init.d/qmanager_tower_failover disable 2>/dev/null
            qlog_info "No active locks — failover stopped and disabled"
        fi

        jq -n '{"success":true,"type":"lte","action":"unlock"}'
    else
        cgi_error "invalid_action" "action must be lock or unlock"
        exit 0
    fi

# =============================================================================
# NR-SA Lock/Unlock
# =============================================================================
elif [ "$LOCK_TYPE" = "nr_sa" ]; then

    if [ "$ACTION" = "lock" ]; then
        nr_pci=$(printf '%s' "$POST_DATA" | jq -r '(.pci) | if . == null then empty else tostring end' 2>/dev/null)
        nr_arfcn=$(printf '%s' "$POST_DATA" | jq -r '(.arfcn) | if . == null then empty else tostring end' 2>/dev/null)
        nr_scs=$(printf '%s' "$POST_DATA" | jq -r '(.scs) | if . == null then empty else tostring end' 2>/dev/null)
        nr_band=$(printf '%s' "$POST_DATA" | jq -r '(.band) | if . == null then empty else tostring end' 2>/dev/null)

        # Validate all fields present
        if [ -z "$nr_pci" ] || [ -z "$nr_arfcn" ] || [ -z "$nr_scs" ] || [ -z "$nr_band" ]; then
            cgi_error "missing_fields" "NR-SA lock requires pci, arfcn, scs, and band"
            exit 0
        fi

        # Validate SCS value
        case "$nr_scs" in
            15|30|60|120|240) ;;  # Valid SCS kHz values
            *)
                cgi_error "invalid_scs" "SCS must be 15, 30, 60, 120, or 240 kHz"
                exit 0
                ;;
        esac

        qlog_info "NR-SA tower lock: PCI=$nr_pci ARFCN=$nr_arfcn SCS=$nr_scs Band=$nr_band"

        result=$(tower_lock_nr "$nr_pci" "$nr_arfcn" "$nr_scs" "$nr_band")
        rc=$?

        if [ $rc -ne 0 ] || [ -z "$result" ]; then
            qlog_error "NR-SA tower lock failed (rc=$rc)"
            cgi_error "modem_error" "Failed to send NR tower lock command"
            exit 0
        fi

        case "$result" in
            *ERROR*)
                qlog_error "NR-SA tower lock AT ERROR: $result"
                cgi_error "at_error" "Modem rejected NR tower lock command"
                exit 0
                ;;
        esac

        qlog_info "NR-SA tower lock applied successfully"

        # Re-apply custom MTU after interface bounce
        mtu_reapply_after_bounce

        # Update config — preserve the user's current failover toggle.
        # Failover is no longer auto-enabled on lock; the user must toggle
        # Signal Failover explicitly via settings.sh.
        tower_config_update_nr "true" "$nr_pci" "$nr_arfcn" "$nr_scs" "$nr_band"

        # Spawn failover watcher only if the user has failover enabled.
        failover_armed=$(tower_spawn_failover_watcher)

        jq -n --argjson fa "$failover_armed" \
            '{"success":true,"type":"nr_sa","action":"lock","failover_armed":$fa}'

    elif [ "$ACTION" = "unlock" ]; then
        # Kill failover watcher BEFORE sending unlock AT command.
        # During the 3-5s modem disconnect from unlock, the daemon could
        # misdetect "no signal" and clear ALL locks (including LTE if active).
        fo_was_enabled=$(tower_config_get ".failover.enabled")
        tower_kill_failover_watcher
        rm -f "$TOWER_FAILOVER_FLAG"

        result=$(tower_unlock_nr)
        rc=$?

        if [ $rc -ne 0 ] || [ -z "$result" ]; then
            qlog_error "NR-SA tower unlock failed (rc=$rc)"
            cgi_error "modem_error" "Failed to clear NR tower lock"
            exit 0
        fi

        case "$result" in
            *ERROR*)
                qlog_error "NR-SA tower unlock AT ERROR: $result"
                cgi_error "at_error" "Modem rejected NR unlock command"
                exit 0
                ;;
        esac

        qlog_info "NR-SA tower lock cleared"

        # Re-apply custom MTU after interface bounce
        mtu_reapply_after_bounce

        # Update config — preserve ALL NR params, just set enabled=false
        tower_config_update '.nr_sa.enabled = false'

        # Check if other lock remains active
        lte_active=$(tower_config_get ".lte.enabled")
        if [ "$lte_active" = "true" ] && [ "$fo_was_enabled" = "true" ]; then
            # LTE lock still active with failover — respawn watcher for it
            tower_spawn_failover_watcher >/dev/null
            qlog_info "LTE lock still active — failover watcher respawned"
        else
            # No other lock — disable failover fully
            tower_config_update '.failover.enabled = false'
            /etc/init.d/qmanager_tower_failover disable 2>/dev/null
            qlog_info "No active locks — failover stopped and disabled"
        fi

        jq -n '{"success":true,"type":"nr_sa","action":"unlock"}'
    else
        cgi_error "invalid_action" "action must be lock or unlock"
        exit 0
    fi

else
    cgi_error "invalid_type" "type must be lte or nr_sa"
    exit 0
fi
