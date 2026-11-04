#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# adaptive_polling.sh — CGI: UI-aware tiered (adaptive) poller backoff
# =============================================================================
# Controls the poller's AT-port cadence when no browser is open. The poller
# keeps local-only work (proc metrics, ping read, write_cache) at the base
# interval so the watchdog's .connectivity data and root .timestamp stay fresh,
# but graduates AT reads to a slower cadence while the UI is idle.
#
# GET:  Returns the five cadence settings + isDefault + the LIVE tier. When the
#       UCI section is ABSENT the endpoint reports the built-in defaults with
#       isDefault=true (absence IS the "default" signal — never seeded).
# POST: action=save — validates the five fields, creates the section if absent,
#       persists, then drops /tmp/qmanager_poller_reload so the poller re-maps
#       its AP_* globals within one cycle.
#
# Config: UCI quecmanager.poller.{enabled,active_grace,idle_interval,
#                                  idle_threshold,deep_idle_interval}
#   enabled            0|1 (truthy unless 0/false) — default 1
#   active_grace       seconds since last UI hit to stay Active — default 20
#   idle_interval      AT-read cadence (s) in the Idle tier — default 15
#   idle_threshold     seconds of idle before dropping to Deep — default 300
#   deep_idle_interval AT-read cadence (s) in the Deep tier — default 60
# The poller (resolve_poller_config) owns the clamp + truthiness mapping.
#
# Endpoint: GET/POST /cgi-bin/quecmanager/system/adaptive_polling.sh
# Install location: /www/cgi-bin/quecmanager/system/adaptive_polling.sh
# =============================================================================

qlog_init "cgi_adaptive_polling"
cgi_headers
cgi_handle_options

RELOAD_FLAG="/tmp/qmanager_poller_reload"
STATUS_FILE="/tmp/qmanager_status.json"

# Built-in defaults (mirrored in qmanager_poller resolve_poller_config).
DEF_ENABLED=1
DEF_ACTIVE_GRACE=20
DEF_IDLE_INTERVAL=15
DEF_IDLE_THRESHOLD=300
DEF_DEEP_INTERVAL=60

# Read the live tier from the poller cache (fallback "active").
read_live_tier() {
    _tier=""
    if [ -f "$STATUS_FILE" ]; then
        _tier=$(jq -r '(.device.poller_tier) | if . == null then empty else tostring end' "$STATUS_FILE" 2>/dev/null)
    fi
    case "$_tier" in
        active|idle|deep) printf '%s' "$_tier" ;;
        *)                printf 'active' ;;
    esac
}

# =============================================================================
# GET — Fetch adaptive-polling settings (presence-aware) + live tier
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Fetching adaptive polling settings"

    tier=$(read_live_tier)

    if uci -q get quecmanager.poller >/dev/null 2>&1; then
        enabled=$(uci -q get quecmanager.poller.enabled 2>/dev/null)
        active_grace=$(uci -q get quecmanager.poller.active_grace 2>/dev/null)
        idle_interval=$(uci -q get quecmanager.poller.idle_interval 2>/dev/null)
        idle_threshold=$(uci -q get quecmanager.poller.idle_threshold 2>/dev/null)
        deep_idle_interval=$(uci -q get quecmanager.poller.deep_idle_interval 2>/dev/null)

        # Fall back to defaults on empty/garbage so a hand-edited UCI never
        # surfaces a blank field to the frontend.
        case "$active_grace"       in ''|*[!0-9]*) active_grace=$DEF_ACTIVE_GRACE ;; esac
        case "$idle_interval"      in ''|*[!0-9]*) idle_interval=$DEF_IDLE_INTERVAL ;; esac
        case "$idle_threshold"     in ''|*[!0-9]*) idle_threshold=$DEF_IDLE_THRESHOLD ;; esac
        case "$deep_idle_interval" in ''|*[!0-9]*) deep_idle_interval=$DEF_DEEP_INTERVAL ;; esac

        # enabled is truthy unless explicitly 0/false.
        case "$enabled" in
            0|false|no|off) enabled_bool=false ;;
            *)              enabled_bool=true ;;
        esac

        jq -n \
            --argjson en "$enabled_bool" \
            --argjson ag "$active_grace" \
            --argjson ii "$idle_interval" \
            --argjson it "$idle_threshold" \
            --argjson di "$deep_idle_interval" \
            --arg tier "$tier" \
            '{success: true,
              settings: {enabled: $en, active_grace: $ag, idle_interval: $ii,
                         idle_threshold: $it, deep_idle_interval: $di},
              isDefault: false,
              tier: $tier}'
    else
        # Section absent — report the defaults with isDefault=true.
        jq -n \
            --argjson ag "$DEF_ACTIVE_GRACE" \
            --argjson ii "$DEF_IDLE_INTERVAL" \
            --argjson it "$DEF_IDLE_THRESHOLD" \
            --argjson di "$DEF_DEEP_INTERVAL" \
            --arg tier "$tier" \
            '{success: true,
              settings: {enabled: true, active_grace: $ag, idle_interval: $ii,
                         idle_threshold: $it, deep_idle_interval: $di},
              isDefault: true,
              tier: $tier}'
    fi
    exit 0
fi

# =============================================================================
# POST — Save adaptive-polling settings
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r 'if .action == null then empty else .action end')
    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    if [ "$ACTION" != "save" ]; then
        cgi_error "unknown_action" "Unknown action: $ACTION"
        exit 0
    fi

    # --- Extract fields. enabled is a JSON boolean; the four cadences are ints.
    ENABLED=$(printf '%s' "$POST_DATA" | jq -r '(.enabled) | if . == null then empty else tostring end')
    ACTIVE_GRACE=$(printf '%s' "$POST_DATA" | jq -r '(.active_grace) | if . == null then empty else tostring end')
    IDLE_INTERVAL=$(printf '%s' "$POST_DATA" | jq -r '(.idle_interval) | if . == null then empty else tostring end')
    IDLE_THRESHOLD=$(printf '%s' "$POST_DATA" | jq -r '(.idle_threshold) | if . == null then empty else tostring end')
    DEEP_IDLE_INTERVAL=$(printf '%s' "$POST_DATA" | jq -r '(.deep_idle_interval) | if . == null then empty else tostring end')

    # --- Validate enabled (must be a real boolean) ---
    case "$ENABLED" in
        true)  ENABLED_UCI=1 ;;
        false) ENABLED_UCI=0 ;;
        *)
            cgi_error "invalid_enabled" "enabled must be a boolean (true or false)"
            exit 0
            ;;
    esac

    # --- Validate the four cadence fields (positive integers) ---
    case "$ACTIVE_GRACE" in
        ''|*[!0-9]*)
            cgi_error "invalid_active_grace" "active_grace must be a non-negative integer"
            exit 0
            ;;
    esac
    case "$IDLE_INTERVAL" in
        ''|*[!0-9]*)
            cgi_error "invalid_idle_interval" "idle_interval must be a non-negative integer"
            exit 0
            ;;
    esac
    case "$IDLE_THRESHOLD" in
        ''|*[!0-9]*)
            cgi_error "invalid_idle_threshold" "idle_threshold must be a non-negative integer"
            exit 0
            ;;
    esac
    case "$DEEP_IDLE_INTERVAL" in
        ''|*[!0-9]*)
            cgi_error "invalid_deep_idle_interval" "deep_idle_interval must be a non-negative integer"
            exit 0
            ;;
    esac

    # --- Persist (create section if absent) + signal the poller ---
    if ! uci -q get quecmanager.poller >/dev/null 2>&1; then
        uci set quecmanager.poller=poller
    fi
    uci set quecmanager.poller.enabled="$ENABLED_UCI"
    uci set quecmanager.poller.active_grace="$ACTIVE_GRACE"
    uci set quecmanager.poller.idle_interval="$IDLE_INTERVAL"
    uci set quecmanager.poller.idle_threshold="$IDLE_THRESHOLD"
    uci set quecmanager.poller.deep_idle_interval="$DEEP_IDLE_INTERVAL"
    uci commit quecmanager

    touch "$RELOAD_FLAG"

    qlog_info "Adaptive polling saved: enabled=$ENABLED_UCI active_grace=$ACTIVE_GRACE idle_interval=$IDLE_INTERVAL idle_threshold=$IDLE_THRESHOLD deep_idle_interval=$DEEP_IDLE_INTERVAL"
    echo '{"success":true}'
    exit 0
fi

# Method not allowed
cgi_error "method_not_allowed" "Only GET and POST are supported"
