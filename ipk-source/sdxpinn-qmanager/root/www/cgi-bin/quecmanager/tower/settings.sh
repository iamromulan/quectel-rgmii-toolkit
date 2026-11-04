#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# settings.sh — CGI Endpoint: Update Tower Lock Settings
# =============================================================================
# Updates persist and failover settings. Persist changes are sent to the
# modem immediately via AT+QNWLOCK="save_ctrl",<lte>,<nr>. Failover settings
# are written to the config file only. Every field is optional; an absent one
# keeps its current value, so a failover save never touches persistence.
#
# POST body (any subset):
#   {"persist_lte": true, "persist_nr": false,
#    "failover_enabled": true, "failover_threshold": 20}
#   "persist": true|false sets both radios (older clients).
#
# Endpoint: POST /cgi-bin/quecmanager/tower/settings.sh
# Install location: /www/cgi-bin/quecmanager/tower/settings.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_tower_settings"
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

# --- Parse fields using jq ---------------------------------------------------
# IMPORTANT: Cannot use `// empty` for booleans — jq treats `false` as falsy,
# so `false // empty` produces nothing. Use `has()` + `tostring` instead.
# "unset" = field not present in POST body (keep current value).
PERSIST=$(printf '%s' "$POST_DATA" | jq -r 'if has("persist") then (.persist | tostring) else "unset" end' 2>/dev/null)
PERSIST_LTE=$(printf '%s' "$POST_DATA" | jq -r 'if has("persist_lte") then (.persist_lte | tostring) else "unset" end' 2>/dev/null)
PERSIST_NR=$(printf '%s' "$POST_DATA" | jq -r 'if has("persist_nr") then (.persist_nr | tostring) else "unset" end' 2>/dev/null)
FO_ENABLED=$(printf '%s' "$POST_DATA" | jq -r 'if has("failover_enabled") then (.failover_enabled | tostring) else "unset" end' 2>/dev/null)
FO_THRESHOLD=$(printf '%s' "$POST_DATA" | jq -r 'if has("failover_threshold") then (.failover_threshold | tostring) else "unset" end' 2>/dev/null)

# --- Validate ----------------------------------------------------------------
for _v in "$PERSIST" "$PERSIST_LTE" "$PERSIST_NR"; do
    case "$_v" in
        unset|true|false) ;;
        *) cgi_error "invalid_persist" "persist values must be true or false"; exit 0 ;;
    esac
done

if [ "$PERSIST" = "unset" ] && [ "$PERSIST_LTE" = "unset" ] && [ "$PERSIST_NR" = "unset" ] \
    && [ "$FO_ENABLED" = "unset" ] && [ "$FO_THRESHOLD" = "unset" ]; then
    cgi_error "no_fields" "No settings fields provided"
    exit 0
fi

# Ensure config exists
tower_config_init

# Read current values as defaults (using jq — safe)
current_persist=$(tower_config_get ".persist")
[ "$current_persist" != "true" ] && current_persist="false"

current_fo_enabled=$(tower_config_get ".failover.enabled")
[ "$current_fo_enabled" != "true" ] && [ "$current_fo_enabled" != "false" ] && current_fo_enabled="false"

current_fo_threshold=$(tower_config_get ".failover.threshold")
[ -z "$current_fo_threshold" ] && current_fo_threshold="20"

# Apply provided values (or keep current if "unset")
[ "$FO_ENABLED" = "unset" ] && FO_ENABLED="$current_fo_enabled"
[ "$FO_THRESHOLD" = "unset" ] && FO_THRESHOLD="$current_fo_threshold"

# Validate threshold range
if [ -n "$FO_THRESHOLD" ]; then
    case "$FO_THRESHOLD" in
        *[!0-9]*)
            cgi_error "invalid_threshold" "Threshold must be a number 0-100"
            exit 0
            ;;
    esac
    if [ "$FO_THRESHOLD" -lt 0 ] 2>/dev/null || [ "$FO_THRESHOLD" -gt 100 ] 2>/dev/null; then
        cgi_error "invalid_threshold" "Threshold must be 0-100"
        exit 0
    fi
fi

qlog_info "Updating tower settings: persist=$PERSIST persist_lte=$PERSIST_LTE persist_nr=$PERSIST_NR failover_enabled=$FO_ENABLED threshold=$FO_THRESHOLD"

# --- Send persist AT command if changed --------------------------------------
# save_ctrl takes both radios in one command, so a one-radio change reads the
# other radio's live value first. An unreadable modem blocks the write rather
# than guessing the radio that was not touched.
persist_ok="true"
applied_lte="null"
applied_nr="null"
new_persist="$current_persist"
if [ "$PERSIST" != "unset" ] || [ "$PERSIST_LTE" != "unset" ] || [ "$PERSIST_NR" != "unset" ]; then
    cur_state=$(tower_read_persist)
    if [ $? -ne 0 ]; then
        qlog_error "Persist read failed; not writing save_ctrl"
        persist_ok="false"
    else
        set -- $cur_state
        cur_lte="$1"
        cur_nr="$2"
        want_lte="$cur_lte"
        want_nr="$cur_nr"
        if [ "$PERSIST" = "true" ]; then
            want_lte="1"
            want_nr="1"
        elif [ "$PERSIST" = "false" ]; then
            want_lte="0"
            want_nr="0"
        fi
        [ "$PERSIST_LTE" = "true" ] && want_lte="1"
        [ "$PERSIST_LTE" = "false" ] && want_lte="0"
        [ "$PERSIST_NR" = "true" ] && want_nr="1"
        [ "$PERSIST_NR" = "false" ] && want_nr="0"

        if [ "$want_lte" != "$cur_lte" ] || [ "$want_nr" != "$cur_nr" ]; then
            result=$(tower_set_persist "$want_lte" "$want_nr")
            rc=$?

            if [ $rc -ne 0 ] || [ -z "$result" ]; then
                qlog_error "Persist AT command failed (rc=$rc)"
                persist_ok="false"
            else
                case "$result" in
                    *ERROR*)
                        qlog_error "Persist AT ERROR: $result"
                        persist_ok="false"
                        ;;
                    *)
                        qlog_info "Persist set lte=$want_lte nr=$want_nr"
                        ;;
                esac
            fi
        fi

        # What the modem holds now: the request if it landed, else what it had.
        if [ "$persist_ok" = "true" ]; then
            fin_lte="$want_lte"
            fin_nr="$want_nr"
        else
            fin_lte="$cur_lte"
            fin_nr="$cur_nr"
        fi
        applied_lte="false"
        applied_nr="false"
        [ "$fin_lte" = "1" ] && applied_lte="true"
        [ "$fin_nr" = "1" ] && applied_nr="true"
        # config.persist mirrors "both radios keep the lock".
        new_persist="false"
        [ "$applied_lte" = "true" ] && [ "$applied_nr" = "true" ] && new_persist="true"
    fi
fi

# --- Update config file using jq (atomic, safe) -----------------------------
tower_config_update_settings "$new_persist" "$FO_ENABLED" "$FO_THRESHOLD"

# --- Ensure failover daemon is running when enabled + lock active ------------
watcher_spawned="false"
if [ "$FO_ENABLED" = "true" ]; then
    lte_active=$(tower_config_get ".lte.enabled")
    nr_active=$(tower_config_get ".nr_sa.enabled")
    if [ "$lte_active" = "true" ] || [ "$nr_active" = "true" ]; then
        # Only spawn if daemon is not already running (avoids resetting settle timer)
        daemon_alive="false"
        if [ -f "$TOWER_FAILOVER_PID" ]; then
            wpid=$(cat "$TOWER_FAILOVER_PID" 2>/dev/null | tr -d ' \n\r')
            [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null && daemon_alive="true"
        fi
        if [ "$daemon_alive" != "true" ]; then
            spawn_result=$(tower_spawn_failover_watcher)
            [ "$spawn_result" = "true" ] && watcher_spawned="true"
            qlog_info "Failover spawn attempt: result=$spawn_result"
        fi
    fi
fi

# --- Kill failover daemon if failover was just disabled ----------------------
if [ "$FO_ENABLED" = "false" ] && [ "$current_fo_enabled" = "true" ]; then
    tower_kill_failover_watcher
    rm -f "$TOWER_FAILOVER_FLAG"
    /etc/init.d/qmanager_tower_failover disable 2>/dev/null
    qlog_info "Failover disabled — killed daemon, disabled init.d"
fi

# --- Response ----------------------------------------------------------------
# persist_lte / persist_nr are each radio's value after this call (null when
# persistence was not part of the request or the modem could not be read).
if [ "$persist_ok" = "true" ]; then
    jq -n \
        --argjson persist "$new_persist" \
        --argjson plte "$applied_lte" \
        --argjson pnr "$applied_nr" \
        --argjson fo_enabled "$FO_ENABLED" \
        --argjson fo_threshold "$FO_THRESHOLD" \
        --argjson ws "$watcher_spawned" \
        '{success: true, persist: $persist, persist_lte: $plte, persist_nr: $pnr, failover_enabled: $fo_enabled, failover_threshold: $fo_threshold, watcher_spawned: $ws}'
else
    jq -n \
        --argjson persist "$new_persist" \
        --argjson plte "$applied_lte" \
        --argjson pnr "$applied_nr" \
        --argjson fo_enabled "$FO_ENABLED" \
        --argjson fo_threshold "$FO_THRESHOLD" \
        --argjson ws "$watcher_spawned" \
        '{success: true, persist_command_failed: true, persist: $persist, persist_lte: $plte, persist_nr: $pnr, failover_enabled: $fo_enabled, failover_threshold: $fo_threshold, watcher_spawned: $ws}'
fi
