#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh
[ -f /usr/lib/qmanager/api_auth.sh ] && . /usr/lib/qmanager/api_auth.sh
[ -f /usr/lib/qmanager/web_port.sh ] && . /usr/lib/qmanager/web_port.sh
# =============================================================================
# prometheus.sh — CGI Endpoint: Prometheus metrics settings (GET + POST)
# =============================================================================
# GET:  Returns the settings, the last-scrape fact and the poller state.
# POST: action=save (enabled + freshness) or action=regenerate_token.
#
# Config: UCI quecmanager.metrics.{enabled,freshness,token}
# State:  /var/run/qmanager/metrics_scrape ("<mode> <uptime_s>", written by the
#         scrape endpoint metrics/prometheus.sh, read by the poller)
#
# The bearer token is returned to the authenticated owner only and is never
# logged, never placed on argv (qm_api_token_generate in api_auth.sh writes it
# through uci batch on stdin; jq reads it from stdin through the printf
# builtin) and never seeded by the installer. Enabling generates the token
# BEFORE enabled=1 is written, so a scrape never sees enabled without a token.
#
# Endpoint: GET/POST /cgi-bin/quecmanager/monitoring/prometheus.sh
# Install location: /www/cgi-bin/quecmanager/monitoring/prometheus.sh
# =============================================================================

qlog_init "cgi_prometheus"
cgi_headers
cgi_handle_options

SCRAPE_FILE="/var/run/qmanager/metrics_scrape"
STATUS_FILE="/tmp/qmanager_status.json"
ENDPOINT_PATH="/cgi-bin/quecmanager/metrics/prometheus.sh"
LEASE_TTL=120

M_ENABLED=0
M_FRESHNESS="adaptive"
M_TOKEN=""
CUR_UP=""
LS_AGE=""
LS_MODE=""
_n=""

# 64 lowercase hex, nothing else.
token_valid() {
    case "$1" in
        ''|*[!0-9a-f]*) return 1 ;;
    esac
    [ "${#1}" -eq 64 ]
}

# New token via the shared helper (generate, validate, uci batch on stdin,
# commit). On failure emits the error envelope and exits.
gen_token_or_fail() {
    local rc
    if command -v qm_api_token_generate >/dev/null 2>&1; then
        qm_api_token_generate metrics
        rc=$?
    else
        rc=2
    fi
    case "$rc" in
        0) return 0 ;;
        2)
            qlog_error "Metrics token generation failed"
            cgi_error "token_generation_failed" "Could not generate a token"
            ;;
        *)
            qlog_error "Metrics token save failed"
            cgi_error "save_failed" "Could not write the token"
            ;;
    esac
    exit 0
}

# Strip leading zeros from $_n in place (ash aborts on $((08))).
n_strip() {
    while [ "${_n#0}" != "$_n" ] && [ "${#_n}" -gt 1 ]; do
        _n="${_n#0}"
    done
}

# Invalid or missing stored values read as the defaults; a malformed stored
# token reads as no token.
load_settings() {
    local v
    M_ENABLED=0
    M_FRESHNESS="adaptive"
    M_TOKEN=""
    v=$(uci -q get quecmanager.metrics.enabled 2>/dev/null)
    [ "$v" = "1" ] && M_ENABLED=1
    v=$(uci -q get quecmanager.metrics.freshness 2>/dev/null)
    case "$v" in
        adaptive|balanced|realtime) M_FRESHNESS="$v" ;;
    esac
    v=$(uci -q get quecmanager.metrics.token 2>/dev/null)
    token_valid "$v" && M_TOKEN="$v"
    return 0
}

read_uptime() {
    local u
    local rest
    CUR_UP=""
    { read -r u rest < /proc/uptime; } 2>/dev/null
    u="${u%%.*}"
    case "$u" in
        ''|*[!0-9]*) return 0 ;;
    esac
    CUR_UP="$u"
}

# Sets LS_AGE / LS_MODE; both stay empty when the file is absent, untrusted,
# malformed or in the future.
load_scrape() {
    local mode
    local sup
    local age
    LS_AGE=""
    LS_MODE=""
    command -v qm_trusted_file >/dev/null 2>&1 || return 0
    qm_trusted_file "$SCRAPE_FILE" || return 0
    { read -r mode sup < "$SCRAPE_FILE"; } 2>/dev/null
    case "$mode" in
        adaptive|balanced|realtime) ;;
        *) return 0 ;;
    esac
    case "$sup" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "${#sup}" -le 10 ] || return 0
    [ -n "$CUR_UP" ] || return 0
    _n="$sup"
    n_strip
    age=$((CUR_UP - _n))
    [ "$age" -ge 0 ] || return 0
    LS_AGE="$age"
    LS_MODE="$mode"
}

# The GET body (also the response to a successful POST).
emit_state() {
    local holding
    local adaptive_enabled
    local tier
    local pe
    local ls_json
    local https_port
    local lh

    load_settings
    read_uptime
    load_scrape

    holding="false"
    if [ "$M_ENABLED" = "1" ] && [ -n "$LS_AGE" ] && [ "$LS_AGE" -le "$LEASE_TTL" ]; then
        case "$LS_MODE" in
            balanced|realtime) holding="true" ;;
        esac
    fi

    adaptive_enabled="true"
    pe=$(uci -q get quecmanager.poller.enabled 2>/dev/null)
    [ "$pe" = "0" ] && adaptive_enabled="false"

    tier=""
    if [ -f "$STATUS_FILE" ]; then
        tier=$(jq -r '.device.poller_tier | if type == "string" then . else empty end' "$STATUS_FILE" 2>/dev/null)
    fi
    case "$tier" in
        active|idle|deep) ;;
        *) tier="" ;;
    esac

    # The HTTPS port the scrape config targets. web_port.sh (custom web ports)
    # owns the effective value when installed; otherwise the first uhttpd https
    # listener, then 443.
    https_port=""
    if command -v wp_conf_https >/dev/null 2>&1; then
        https_port=$(wp_conf_https 2>/dev/null)
    fi
    if [ -z "$https_port" ]; then
        lh=$(uci -q get uhttpd.main.listen_https 2>/dev/null)
        lh="${lh%% *}"
        https_port="${lh##*:}"
    fi
    case "$https_port" in
        ''|*[!0-9]*|0*|??????*) https_port=443 ;;
    esac

    ls_json="null"
    if [ -n "$LS_AGE" ]; then
        ls_json=$(jq -n -c --argjson age "$LS_AGE" --arg mode "$LS_MODE" \
            '{age_seconds: $age, mode: $mode}')
    fi

    # The token travels on stdin (printf builtin), never on jq's argv.
    printf '%s\n' "$M_TOKEN" | jq -n -R \
        --argjson enabled "$M_ENABLED" \
        --arg freshness "$M_FRESHNESS" \
        --arg endpoint "$ENDPOINT_PATH" \
        --argjson last_scrape "$ls_json" \
        --argjson holding "$holding" \
        --argjson adaptive "$adaptive_enabled" \
        --arg tier "$tier" \
        --argjson https_port "$https_port" \
        'input as $token | {
            success: true,
            settings: {
                enabled: ($enabled == 1),
                freshness: $freshness,
                token: $token
            },
            endpoint_path: $endpoint,
            https_port: $https_port,
            last_scrape: $last_scrape,
            holding: $holding,
            poller: {
                adaptive_enabled: $adaptive,
                tier: (if $tier == "" then null else $tier end)
            }
        }'
}

# Keep the poller's scrape file consistent with a saved mode: disabling removes
# it; otherwise the mode is rewritten and the uptime is kept, so a mode change
# takes effect within one poller cycle. A write failure is not fatal.
sync_scrape_file() {
    local mode
    local sup
    [ -f "$SCRAPE_FILE" ] || return 0
    if [ "$M_ENABLED" != "1" ]; then
        rm -f "$SCRAPE_FILE"
        return 0
    fi
    command -v qm_atomic_write >/dev/null 2>&1 || return 0
    { read -r mode sup < "$SCRAPE_FILE"; } 2>/dev/null
    case "$sup" in
        ''|*[!0-9]*) rm -f "$SCRAPE_FILE"; return 0 ;;
    esac
    printf '%s %s\n' "$M_FRESHNESS" "$sup" | qm_atomic_write "$SCRAPE_FILE" || true
}

# =============================================================================
# GET
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    emit_state
    exit 0
fi

# =============================================================================
# POST
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    printf '%s' "$POST_DATA" | jq -e 'type == "object"' >/dev/null 2>&1 || {
        cgi_error "invalid_json" "Request body is not a JSON object"
        exit 0
    }

    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action | if type == "string" then . else empty end')
    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: save
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "save" ]; then
        en=$(printf '%s' "$POST_DATA" | jq -r 'if (.enabled | type) == "boolean" then (.enabled | tostring) else empty end')
        fr=$(printf '%s' "$POST_DATA" | jq -r 'if (.freshness | type) == "string" then .freshness else empty end')

        case "$en" in
            true) new_enabled=1 ;;
            false) new_enabled=0 ;;
            *) cgi_error "invalid_value" "enabled"; exit 0 ;;
        esac
        case "$fr" in
            adaptive|balanced|realtime) ;;
            *) cgi_error "invalid_value" "freshness"; exit 0 ;;
        esac

        load_settings
        # Token first: a scrape must never see enabled=1 without a valid token.
        if [ "$new_enabled" = "1" ] && [ -z "$M_TOKEN" ]; then
            gen_token_or_fail
        fi

        printf 'set quecmanager.metrics=metrics\nset quecmanager.metrics.enabled=%s\nset quecmanager.metrics.freshness=%s\n' \
            "$new_enabled" "$fr" | uci batch
        batch_rc=$?
        if [ "$batch_rc" -ne 0 ] || ! uci commit quecmanager 2>/dev/null; then
            qlog_error "Metrics settings save failed"
            cgi_error "save_failed" "Could not write the settings"
            exit 0
        fi

        load_settings
        sync_scrape_file
        qlog_info "Metrics settings saved (enabled=$M_ENABLED freshness=$M_FRESHNESS)"
        emit_state
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: regenerate_token
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "regenerate_token" ]; then
        load_settings
        if [ "$M_ENABLED" != "1" ]; then
            cgi_error "invalid_value" "enabled"
            exit 0
        fi

        gen_token_or_fail

        qlog_info "Metrics token regenerated"
        emit_state
        exit 0
    fi

    cgi_error "unknown_action" "Unknown action: $ACTION"
    exit 0
fi

cgi_error "method_not_allowed" "Only GET and POST are supported"
