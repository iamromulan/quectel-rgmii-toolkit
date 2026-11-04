#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh
# =============================================================================
# sms_forwarding.sh — CGI Endpoint: SMS Forwarding Settings (GET + POST)
# =============================================================================
# GET:  Returns current forwarding settings + recent send-failure records.
# POST: action=save_settings  -> persist enabled/target_phone, toggle service
#       action=clear_failures  -> drop the failures file
#       action=send_test       -> one-off test SMS to the CONFIGURED target
#
# Settings live in UCI (quecmanager.sms_forwarding.*). The daemon
# (qmanager_sms_forward) reads them and forwards inbound SMS. A reload flag plus
# init.d enable/start (or stop/disable) keeps the running daemon in sync.
#
# Config:  quecmanager.sms_forwarding.enabled ('0'/'1'), .target_phone
# Reload:  /tmp/qmanager_sms_forward_reload
# Output:  /tmp/qmanager_sms_forward_failures.json (written by the daemon)
#
# Endpoint: GET/POST /cgi-bin/quecmanager/cellular/sms_forwarding.sh
# Install location: /www/cgi-bin/quecmanager/cellular/sms_forwarding.sh
# =============================================================================

qlog_init "cgi_sms_forwarding"
cgi_headers
cgi_handle_options

RELOAD_FLAG="/tmp/qmanager_sms_forward_reload"
FAILURES_FILE="/tmp/qmanager_sms_forward_failures.json"
INITD="/etc/init.d/qmanager_sms_forward"

# SMS transport: /usr/bin/qsms -> qmanager_atd (one JSON line, rc 0/1). The
# broker serializes on /var/lock/qmanager.lock itself; never wrap it in flock.
_SF_QSMS="/usr/bin/qsms"

# Validation: E.164-ish — optional +, first digit 1-9, total 7-15 digits.
# Reused verbatim from monitoring/sms_alerts.sh.
_validate_phone() {
    _vp=$(printf '%s' "$1" | sed 's/^+//')
    case "$_vp" in
        ''|*[!0-9]*) return 1 ;;
    esac
    _vp_len=${#_vp}
    [ "$_vp_len" -lt 7 ] || [ "$_vp_len" -gt 15 ] && return 1
    _vp_first=$(printf '%s' "$_vp" | cut -c1)
    [ "$_vp_first" = "0" ] && return 1
    return 0
}

# Run one qsms command. On success prints its JSON; on failure prints a human
# message ("<code>: <detail>") built from the failure envelope.
_sf_sms_run() {
    _sf_out=$("$_SF_QSMS" "$@" 2>/dev/null)
    _sf_rc=$?
    if [ "$_sf_rc" -eq 0 ]; then
        printf '%s' "$_sf_out"
        return 0
    fi
    _sf_code=$(printf '%s' "$_sf_out" | jq -r 'if .error == null then empty else .error end' 2>/dev/null)
    _sf_detail=$(printf '%s' "$_sf_out" | jq -r 'if .detail == null then empty else (.detail | tostring) end' 2>/dev/null)
    printf '%s' "${_sf_code:-qsms failed (rc=$_sf_rc)}${_sf_detail:+: $_sf_detail}"
    return 1
}

# =============================================================================
# GET — Fetch settings + failures
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Fetching SMS forwarding settings"

    enabled_raw=$(uci -q get quecmanager.sms_forwarding.enabled 2>/dev/null)
    target_phone=$(uci -q get quecmanager.sms_forwarding.target_phone 2>/dev/null)
    [ "$enabled_raw" = "1" ] && enabled_json="true" || enabled_json="false"
    [ -z "$target_phone" ] && target_phone=""

    # B5.13: show only the list the daemon wrote (root-owned regular file)
    if command -v qm_trusted_file >/dev/null 2>&1 && qm_trusted_file "$FAILURES_FILE" && [ -s "$FAILURES_FILE" ]; then
        failures=$(jq -c 'if type == "array" then . else [] end' "$FAILURES_FILE" 2>/dev/null)
    fi
    [ -z "$failures" ] && failures="[]"
    printf '%s' "$failures" | jq empty 2>/dev/null || failures="[]"

    jq -n \
        --argjson enabled "$enabled_json" \
        --arg target_phone "$target_phone" \
        --argjson failures "$failures" \
        '{
            success: true,
            settings: {
                enabled: $enabled,
                target_phone: $target_phone
            },
            failures: $failures,
            failure_count: ($failures | length)
        }'
    exit 0
fi

# =============================================================================
# POST — save_settings / clear_failures / send_test
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r 'if .action == null then empty else .action end')

    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    # --- action: save_settings ----------------------------------------------
    if [ "$ACTION" = "save_settings" ]; then
        # enabled may arrive as bool true/false or "0"/"1"; normalize to 0/1.
        ENABLED_RAW=$(printf '%s' "$POST_DATA" | jq -r 'if .enabled == null then empty else (.enabled | tostring) end')
        case "$ENABLED_RAW" in
            true|1) ENABLED=1 ;;
            false|0) ENABLED=0 ;;
            *) ENABLED=0 ;;
        esac

        TARGET=$(printf '%s' "$POST_DATA" | jq -r 'if .target_phone == null then "" else .target_phone end')

        # When enabling, the target must be valid. When disabling, an empty or
        # bad number is tolerated (the daemon idles regardless).
        if [ "$ENABLED" = "1" ]; then
            if ! _validate_phone "$TARGET"; then
                cgi_error "invalid_phone" "target_phone is not a valid phone number"
                exit 0
            fi
        fi

        uci set quecmanager.sms_forwarding.enabled="$ENABLED"
        uci set quecmanager.sms_forwarding.target_phone="$TARGET"
        uci commit quecmanager 2>/dev/null

        # Signal the running daemon to re-read config within one cycle.
        touch "$RELOAD_FLAG" 2>/dev/null

        # Reflect enabled state in the init.d service.
        if [ "$ENABLED" = "1" ]; then
            "$INITD" enable 2>/dev/null
            ( "$INITD" restart >/dev/null 2>&1 & )
            qlog_info "SMS forwarding enabled, daemon enabled and started"
        else
            "$INITD" stop >/dev/null 2>&1
            "$INITD" disable 2>/dev/null
            qlog_info "SMS forwarding disabled, daemon stopped and disabled"
        fi

        [ "$ENABLED" = "1" ] && enabled_json="true" || enabled_json="false"
        jq -n \
            --argjson enabled "$enabled_json" \
            --arg target_phone "$TARGET" \
            '{
                success: true,
                settings: {
                    enabled: $enabled,
                    target_phone: $target_phone
                }
            }'
        exit 0
    fi

    # --- action: clear_failures ---------------------------------------------
    if [ "$ACTION" = "clear_failures" ]; then
        rm -f "$FAILURES_FILE"
        qlog_info "SMS forwarding failures cleared"
        cgi_success
        exit 0
    fi

    # --- action: send_test --------------------------------------------------
    # Tests the REAL configured target (never a number from the request body),
    # so the UI can verify the forwarding send path end-to-end. Single attempt.
    if [ "$ACTION" = "send_test" ]; then
        TARGET=$(uci -q get quecmanager.sms_forwarding.target_phone 2>/dev/null)
        if ! _validate_phone "$TARGET"; then
            cgi_error "invalid_phone" "no valid target_phone configured"
            exit 0
        fi

        PHONE=$(printf '%s' "$TARGET" | sed 's/^+//')
        BODY="From QManager: SMS forwarding test"

        qlog_info "SMS forwarding test send to $PHONE"
        result=$(_sf_sms_run send "$PHONE" "$BODY")
        rc=$?

        if [ "$rc" -ne 0 ]; then
            qlog_error "SMS forwarding test send failed (rc=$rc): $result"
            cgi_error "send_failed" "$result"
            exit 0
        fi

        qlog_info "SMS forwarding test send succeeded to $PHONE"
        cgi_success
        exit 0
    fi

    # --- Unknown action ------------------------------------------------------
    cgi_error "invalid_action" "action must be save_settings, clear_failures, or send_test"
    exit 0
fi

# --- Method not allowed ------------------------------------------------------
cgi_method_not_allowed
