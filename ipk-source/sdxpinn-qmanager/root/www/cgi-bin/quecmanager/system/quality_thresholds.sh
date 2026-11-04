#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# Single alert wait resolver (cq_alert_after_min). Guarded: BusyBox ash exits
# when `.` cannot find its file.
if [ -f /usr/lib/qmanager/conn_state.sh ]; then
    . /usr/lib/qmanager/conn_state.sh
else
    cq_alert_after_min() { CQ_ALERT_AFTER_MIN=5; }
fi
# =============================================================================
# quality_thresholds.sh — CGI: Connection Quality Thresholds (GET + POST)
# =============================================================================
# GET:  Returns the latency + loss presets and the alert wait. When neither
#       preset is stored the endpoint reports tolerant/tolerant with
#       isDefault=true (the absence IS the "default" signal; the section can
#       exist holding only alert_after_min, written by monitoring/alerts.sh).
# POST: action=save — validates both presets, creates the section if absent,
#       persists, then drops /tmp/qmanager_quality_reload so the poller re-maps
#       the presets to its QUALITY_* event-threshold globals within one cycle.
#
# Config: UCI quecmanager.quality_thresholds.{latency_preset,loss_preset,
#         alert_after_min}
#   latency_preset ∈ standard | tolerant | very-tolerant | custom
#   loss_preset    ∈ standard | tolerant | very-tolerant | custom
#   alert_after_min  optional on POST, 1-60 minutes: the ONE outage wait every
#                    alert channel uses (absent = resolved by cq_alert_after_min)
# The poller (resolve_quality_thresholds) owns the preset->numeric mapping.
#
# Endpoint: GET/POST /cgi-bin/quecmanager/system/quality_thresholds.sh
# Install location: /www/cgi-bin/quecmanager/system/quality_thresholds.sh
# =============================================================================

qlog_init "cgi_quality_thresholds"
cgi_headers
cgi_handle_options

RELOAD_FLAG="/tmp/qmanager_quality_reload"
# The watchdog now shares these thresholds for its quality-based recovery, but
# does NOT consume qmanager_quality_reload — it reads qmanager_watchcat_reload.
# A threshold edit must touch BOTH or recovery never sees the new values.
WATCHCAT_RELOAD_FLAG="/tmp/qmanager_watchcat_reload"

# Validate numeric field: returns 0 if valid int in [min,max], else 1.
validate_int() {
    local val="$1"
    local min="$2"
    local max="$3"
    case "$val" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$val" -ge "$min" ] 2>/dev/null && [ "$val" -le "$max" ] 2>/dev/null
}

# =============================================================================
# GET — Fetch quality thresholds (presence-aware)
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Fetching quality thresholds"

    cq_alert_after_min
    alert_after_min="$CQ_ALERT_AFTER_MIN"

    if uci -q get quecmanager.quality_thresholds.latency_preset >/dev/null 2>&1 || \
       uci -q get quecmanager.quality_thresholds.loss_preset >/dev/null 2>&1; then
        latency_preset=$(uci -q get quecmanager.quality_thresholds.latency_preset 2>/dev/null)
        [ -z "$latency_preset" ] && latency_preset="tolerant"
        loss_preset=$(uci -q get quecmanager.quality_thresholds.loss_preset 2>/dev/null)
        [ -z "$loss_preset" ] && loss_preset="tolerant"
        latency_custom=$(uci -q get quecmanager.quality_thresholds.latency_custom_ms 2>/dev/null)
        loss_custom=$(uci -q get quecmanager.quality_thresholds.loss_custom_pct 2>/dev/null)

        # custom_ms/custom_pct are JSON null for named presets, the stored int
        # for custom. (Decision: named presets carry null, not a resolved value.)
        latency_custom_json="null"
        case "$latency_custom" in
            ''|*[!0-9]*) latency_custom_json="null" ;;
            *) latency_custom_json="$latency_custom" ;;
        esac
        loss_custom_json="null"
        case "$loss_custom" in
            ''|*[!0-9]*) loss_custom_json="null" ;;
            *) loss_custom_json="$loss_custom" ;;
        esac

        jq -n \
            --arg lat "$latency_preset" \
            --arg loss "$loss_preset" \
            --argjson lat_custom "$latency_custom_json" \
            --argjson loss_custom "$loss_custom_json" \
            --argjson wait "$alert_after_min" \
            '{success: true,
              thresholds: {
                latency: {preset: $lat, custom_ms: $lat_custom},
                loss: {preset: $loss, custom_pct: $loss_custom}
              },
              alert_after_min: $wait,
              isDefault: false}'
    else
        # Section absent — report the default with isDefault=true.
        jq -n --argjson wait "$alert_after_min" '{success: true,
                thresholds: {
                  latency: {preset: "tolerant", custom_ms: null},
                  loss: {preset: "tolerant", custom_pct: null}
                },
                alert_after_min: $wait,
                isDefault: true}'
    fi
    exit 0
fi

# =============================================================================
# POST — Save quality thresholds
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

    LATENCY_PRESET=$(printf '%s' "$POST_DATA" | jq -r '.latency_preset // empty')
    LOSS_PRESET=$(printf '%s' "$POST_DATA" | jq -r '.loss_preset // empty')
    LATENCY_CUSTOM=$(printf '%s' "$POST_DATA" | jq -r '.latency_custom_ms | if . == null then empty else tostring end')
    LOSS_CUSTOM=$(printf '%s' "$POST_DATA" | jq -r '.loss_custom_pct | if . == null then empty else tostring end')
    ALERT_AFTER=$(printf '%s' "$POST_DATA" | jq -r '.alert_after_min | if . == null then empty else tostring end')

    # --- Validate both against the 4-value allowlist (custom added in Pass A) ---
    case "$LATENCY_PRESET" in
        standard|tolerant|very-tolerant|custom) ;;
        *)
            cgi_error "invalid_preset" "latency_preset must be one of: standard, tolerant, very-tolerant, custom"
            exit 0
            ;;
    esac
    case "$LOSS_PRESET" in
        standard|tolerant|very-tolerant|custom) ;;
        *)
            cgi_error "invalid_preset" "loss_preset must be one of: standard, tolerant, very-tolerant, custom"
            exit 0
            ;;
    esac

    # --- When a preset is custom, REQUIRE + validate its numeric companion ---
    if [ "$LATENCY_PRESET" = "custom" ]; then
        if ! validate_int "$LATENCY_CUSTOM" 1 10000; then
            cgi_error "invalid_custom_latency" "latency_custom_ms must be an integer 1-10000 when latency_preset is custom"
            exit 0
        fi
    fi
    if [ "$LOSS_PRESET" = "custom" ]; then
        if ! validate_int "$LOSS_CUSTOM" 0 100; then
            cgi_error "invalid_custom_loss" "loss_custom_pct must be an integer 0-100 when loss_preset is custom"
            exit 0
        fi
    fi

    # --- Optional single alert wait (absent = unchanged) ---
    if [ -n "$ALERT_AFTER" ] && ! validate_int "$ALERT_AFTER" 1 60; then
        cgi_error "invalid_threshold" "alert_after_min must be an integer 1-60"
        exit 0
    fi

    # --- Persist (create section if absent) + signal poller AND watchdog ---
    if ! uci -q get quecmanager.quality_thresholds >/dev/null 2>&1; then
        uci set quecmanager.quality_thresholds=quality_thresholds
    fi
    uci set quecmanager.quality_thresholds.latency_preset="$LATENCY_PRESET"
    uci set quecmanager.quality_thresholds.loss_preset="$LOSS_PRESET"

    # Persist or clear the custom companion. Named presets clear the stale
    # custom value (cleaner — the resolved number always comes from the table).
    if [ "$LATENCY_PRESET" = "custom" ]; then
        uci set quecmanager.quality_thresholds.latency_custom_ms="$LATENCY_CUSTOM"
    else
        uci -q delete quecmanager.quality_thresholds.latency_custom_ms 2>/dev/null
    fi
    if [ "$LOSS_PRESET" = "custom" ]; then
        uci set quecmanager.quality_thresholds.loss_custom_pct="$LOSS_CUSTOM"
    else
        uci -q delete quecmanager.quality_thresholds.loss_custom_pct 2>/dev/null
    fi

    if [ -n "$ALERT_AFTER" ]; then
        uci set quecmanager.quality_thresholds.alert_after_min="$ALERT_AFTER"
    fi

    uci commit quecmanager

    # Poller (events) AND watchdog (recovery) both consume these thresholds via
    # SEPARATE reload flags — touch both or one consumer goes stale.
    touch "$RELOAD_FLAG"
    touch "$WATCHCAT_RELOAD_FLAG"

    qlog_info "Quality thresholds saved: latency=$LATENCY_PRESET loss=$LOSS_PRESET"
    echo '{"success":true}'
    exit 0
fi

# Method not allowed
cgi_error "method_not_allowed" "Only GET and POST are supported"
