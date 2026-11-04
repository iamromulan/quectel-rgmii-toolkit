#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# ping_profile.sh — CGI Endpoint: Connection Quality / Ping Profile (GET + POST)
# =============================================================================
# GET:  Returns the active ping profile name + the IPv4/IPv6 ICMP probe targets,
#       plus the effective cadence (interval_sec, fail_secs, recover_secs).
# POST: action=save — validates + persists profile + targets, then drops the
#       /tmp/qmanager_ping_reload flag so qmanager_ping re-reads within one cycle.
#
# Config: UCI quecmanager.ping_profile.{profile,target_ipv4,target_ipv6}
#   profile      ∈ sensitive | regular | relaxed | quiet  (daemon owns params)
#   target_ipv4  — IPv4 literal or hostname the daemon ICMP-probes first
#   target_ipv6  — IPv6 literal or hostname used as the fallback probe
#
# Targets are ICMP hosts (NOT HTTP URLs) — no scheme is prepended. Both GET and
# POST use the snake_case keys target_ipv4 / target_ipv6.
#
# Endpoint: GET/POST /cgi-bin/quecmanager/system/ping_profile.sh
# Install location: /www/cgi-bin/quecmanager/system/ping_profile.sh
# =============================================================================

qlog_init "cgi_ping_profile"
cgi_headers
cgi_handle_options

RELOAD_FLAG="/tmp/qmanager_ping_reload"
DEFAULT_TARGET_IPV4="1.1.1.1"
DEFAULT_TARGET_IPV6="2606:4700:4700::1111"

# Cadence comes from conn_state_cadence (the same table qmanager_ping runs).
# Guarded: a missing lib must not abort the CGI; fall back to relaxed.
[ -f /usr/lib/qmanager/conn_state.sh ] && . /usr/lib/qmanager/conn_state.sh
if ! command -v conn_state_cadence >/dev/null 2>&1; then
    conn_state_cadence() {
        CQ_CFG_PROFILE="relaxed"
        CQ_CFG_INTERVAL_SEC=5
        CQ_CFG_FAIL_SECS=15
        CQ_CFG_RECOVER_SECS=10
    }
fi

# Ensure the UCI section exists with concrete defaults (seed-on-read).
ensure_ping_profile_config() {
    uci -q get quecmanager.ping_profile >/dev/null 2>&1 && return
    uci set quecmanager.ping_profile=ping_profile
    uci set quecmanager.ping_profile.profile='relaxed'
    uci set quecmanager.ping_profile.target_ipv4="$DEFAULT_TARGET_IPV4"
    uci set quecmanager.ping_profile.target_ipv6="$DEFAULT_TARGET_IPV6"
    uci commit quecmanager
}

# Validate an ICMP probe host server-side (IPv4 literal / IPv6 literal / hostname).
# Common rules: trimmed, non-empty, length <= 128, no interior whitespace, free of
# shell/HTML metacharacters. The per-family charset is passed as $2:
#   ipv4 -> [0-9A-Za-z.-]   (IPv4 literal or hostname)
#   ipv6 -> [0-9A-Fa-f:.%]  (IPv6 literal incl. zone id)
# No scheme is prepended. Returns 0 = valid (echoes trimmed host), 1 = invalid.
validate_target() {
    local host
    local family="$2"

    # Trim leading/trailing whitespace.
    host=$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    # Non-empty.
    [ -n "$host" ] || return 1

    # Length <= 128 (BusyBox-safe length count).
    if [ "${#host}" -gt 128 ]; then
        return 1
    fi

    # No interior whitespace (space or tab).
    case "$host" in
        *" "*|*"	"*) return 1 ;;
    esac

    # Reject shell/HTML metacharacters: ` $ ( ) ; | < > " \
    case "$host" in
        *'`'*|*'$'*|*'('*|*')'*|*';'*|*'|'*|*'<'*|*'>'*|*'"'*|*'\'*) return 1 ;;
    esac

    # Per-family charset whitelist. Reject any character outside the allowed set.
    case "$family" in
        ipv4)
            case "$host" in
                *[!0-9A-Za-z.-]*) return 1 ;;
            esac
            ;;
        ipv6)
            case "$host" in
                *[!0-9A-Fa-f:.%]*) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac

    printf '%s' "$host"
    return 0
}

# =============================================================================
# GET — Fetch active ping profile + targets
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Fetching ping profile"
    ensure_ping_profile_config

    profile=$(uci -q get quecmanager.ping_profile.profile 2>/dev/null)
    [ -z "$profile" ] && profile="relaxed"
    target_ipv4=$(uci -q get quecmanager.ping_profile.target_ipv4 2>/dev/null)
    [ -z "$target_ipv4" ] && target_ipv4="$DEFAULT_TARGET_IPV4"
    target_ipv6=$(uci -q get quecmanager.ping_profile.target_ipv6 2>/dev/null)
    [ -z "$target_ipv6" ] && target_ipv6="$DEFAULT_TARGET_IPV6"

    # interval_override is written exclusively by the Watchdog page; reflected
    # here read-only so the Sensitivity card can show "overridden by Watchdog".
    interval_override=$(uci -q get quecmanager.ping_profile.interval_override 2>/dev/null)
    case "$interval_override" in
        ''|*[!0-9]*) interval_override_json="null" ;;
        *)           interval_override_json="$interval_override" ;;
    esac

    # Effective cadence from UCI (right even while the daemon is down).
    # effective_interval is kept for existing consumers; it equals interval_sec.
    conn_state_cadence

    jq -n \
        --arg profile "$profile" \
        --arg target_ipv4 "$target_ipv4" \
        --arg target_ipv6 "$target_ipv6" \
        --argjson interval_override "$interval_override_json" \
        --argjson interval_sec "$CQ_CFG_INTERVAL_SEC" \
        --argjson fail_secs "$CQ_CFG_FAIL_SECS" \
        --argjson recover_secs "$CQ_CFG_RECOVER_SECS" \
        '{success: true, profile: $profile, target_ipv4: $target_ipv4, target_ipv6: $target_ipv6,
          interval_override: $interval_override, effective_interval: $interval_sec,
          interval_sec: $interval_sec, fail_secs: $fail_secs, recover_secs: $recover_secs}'
    exit 0
fi

# =============================================================================
# POST — Save ping profile + targets
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty')
    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    if [ "$ACTION" != "save" ]; then
        cgi_error "unknown_action" "Unknown action: $ACTION"
        exit 0
    fi

    ensure_ping_profile_config

    PROFILE=$(printf '%s' "$POST_DATA" | jq -r '.profile // empty')
    RAW_T4=$(printf '%s' "$POST_DATA" | jq -r '.target_ipv4 // empty')
    RAW_T6=$(printf '%s' "$POST_DATA" | jq -r '.target_ipv6 // empty')

    # --- Validate profile against the 4-value allowlist ---
    case "$PROFILE" in
        sensitive|regular|relaxed|quiet) ;;
        *)
            cgi_error "invalid_profile" "profile must be one of: sensitive, regular, relaxed, quiet"
            exit 0
            ;;
    esac

    # --- Validate each target against its family charset ---
    T4=$(validate_target "$RAW_T4" "ipv4") || {
        cgi_error "invalid_target" "target_ipv4 is not a valid IPv4 address or hostname"
        exit 0
    }
    T6=$(validate_target "$RAW_T6" "ipv6") || {
        cgi_error "invalid_target" "target_ipv6 is not a valid IPv6 address"
        exit 0
    }

    # --- Persist + signal the daemon ---
    uci set quecmanager.ping_profile.profile="$PROFILE"
    uci set quecmanager.ping_profile.target_ipv4="$T4"
    uci set quecmanager.ping_profile.target_ipv6="$T6"
    uci commit quecmanager

    touch "$RELOAD_FLAG"

    qlog_info "Ping profile saved: profile=$PROFILE v4=$T4 v6=$T6"
    echo '{"success":true}'
    exit 0
fi

# Method not allowed
cgi_error "method_not_allowed" "Only GET and POST are supported"
