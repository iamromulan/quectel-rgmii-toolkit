#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh
# =============================================================================
# watchdog.sh — CGI Endpoint: Watchdog Settings & Status (GET + POST)
# =============================================================================
# GET:  Returns current watchdog configuration (UCI) + live status.
# POST: Saves settings, dismisses SIM swap, or requests SIM revert. A save
#       may carry only one card's fields: absent keys are left untouched.
#
# Config: UCI quecmanager.watchcat.*
# State:  /tmp/qmanager_watchcat.json (read-only, written by daemon)
#
# Endpoint: GET/POST /cgi-bin/quecmanager/monitoring/watchdog.sh
# Install location: /www/cgi-bin/quecmanager/monitoring/watchdog.sh
# =============================================================================

qlog_init "cgi_watchdog"
cgi_headers
cgi_handle_options

WATCHCAT_STATE="/tmp/qmanager_watchcat.json"
SIM_SWAP_FLAG="/tmp/qmanager_sim_swap_detected"
SIM_FAILOVER_FILE="/tmp/qmanager_sim_failover"
RELOAD_FLAG="/tmp/qmanager_watchcat_reload"
PING_RELOAD_FLAG="/tmp/qmanager_ping_reload"
REVERT_FLAG="/tmp/qmanager_watchcat_revert_sim"
DISABLED_FLAG="/tmp/qmanager_watchcat_disabled"

# Ensure UCI section exists with defaults.
# Two responsibilities, both idempotent:
#   1. Seed the section on first run with the current (Pass A) schema.
#   2. Defensively migrate a legacy `max_failures` value into `fail_threshold`
#      if a device hits this CGI before the installer migration ran.
ensure_watchcat_config() {
    if uci -q get quecmanager.watchcat >/dev/null 2>&1; then
        # Section exists — run the defensive legacy migration only.
        migrate_fail_threshold
        return
    fi
    uci set quecmanager.watchcat=watchcat
    uci set quecmanager.watchcat.enabled=0
    uci set quecmanager.watchcat.fail_threshold=5
    uci set quecmanager.watchcat.check_interval=10
    uci set quecmanager.watchcat.cooldown=60
    uci set quecmanager.watchcat.tier1_enabled=1
    uci set quecmanager.watchcat.tier2_enabled=1
    uci set quecmanager.watchcat.tier3_enabled=0
    uci set quecmanager.watchcat.tier4_enabled=1
    uci set quecmanager.watchcat.backup_sim_slot=
    uci set quecmanager.watchcat.max_reboots_per_hour=3
    uci set quecmanager.watchcat.quality_enabled=0
    uci set quecmanager.watchcat.quality_consecutive=5
    uci set quecmanager.watchcat.ssr_aware=1
    uci set quecmanager.watchcat.ssr_grace=45
    uci set quecmanager.watchcat.primary_recheck_enabled=0
    uci set quecmanager.watchcat.primary_recheck_interval=30
    uci commit quecmanager
}

# Defensive migration: if a legacy max_failures exists and fail_threshold is
# absent, copy the value across and delete the old key (mirrors the installer).
# Idempotent: a no-op once fail_threshold is present.
migrate_fail_threshold() {
    local legacy
    local current
    current=$(uci -q get quecmanager.watchcat.fail_threshold 2>/dev/null)
    [ -n "$current" ] && return
    legacy=$(uci -q get quecmanager.watchcat.max_failures 2>/dev/null)
    if [ -n "$legacy" ]; then
        uci set quecmanager.watchcat.fail_threshold="$legacy"
        uci -q delete quecmanager.watchcat.max_failures 2>/dev/null
        uci commit quecmanager
    fi
}

# Read a UCI value with fallback
uci_get() {
    local val
    val=$(uci -q get "quecmanager.watchcat.$1" 2>/dev/null)
    if [ -z "$val" ]; then
        echo "$2"
    else
        echo "$val"
    fi
}

# Coerce a value that is later passed to jq --argjson. A bad UCI value or a
# half-written state file must degrade to the default, never kill the GET.
# coerce_int: plain decimal digits (no leading zero), else the default.
coerce_int() {
    case "$1" in
        ''|*[!0-9]*|0[0-9]*) echo "$2" ;;
        *) echo "$1" ;;
    esac
}

# coerce_bool: 0 or 1, else the default.
coerce_bool() {
    case "$1" in
        0|1) echo "$1" ;;
        *) echo "$2" ;;
    esac
}

# json_or_default <type> <raw> <default>: <raw> re-emitted as one compact JSON
# document when it is exactly one value of <type> (object/array), else the
# default. An empty or garbage file lands on the default.
json_or_default() {
    local out
    out=$(printf '%s' "$2" | jq -c -s -e --arg t "$1" \
        'if length == 1 and (.[0] | type) == $t then .[0] else empty end' 2>/dev/null) || out=""
    if [ -n "$out" ]; then
        printf '%s' "$out"
    else
        printf '%s' "$3"
    fi
}

# Recent watchdog reboots (Tier-4 ledger rows) come from wd_ledger.sh. Guarded:
# a missing lib must not abort the CGI; the stub reports no reboots.
[ -f /usr/lib/qmanager/wd_ledger.sh ] && . /usr/lib/qmanager/wd_ledger.sh
if ! command -v wd_ledger_recent_json >/dev/null 2>&1; then
    wd_ledger_recent_json() { echo '[]'; }
fi

# Probe cadence comes from conn_state_cadence (the same table qmanager_ping
# runs). Guarded: a missing lib must not abort the CGI; fall back to relaxed.
[ -f /usr/lib/qmanager/conn_state.sh ] && . /usr/lib/qmanager/conn_state.sh
if ! command -v conn_state_cadence >/dev/null 2>&1; then
    conn_state_cadence() {
        CQ_CFG_PROFILE="relaxed"
        CQ_CFG_PROFILE_INTERVAL_SEC=5
        CQ_CFG_INTERVAL_SEC=5
        CQ_CFG_FAIL_SECS=15
        CQ_CFG_RECOVER_SECS=10
    }
fi

# Resolve a quality preset (latency) to a numeric ms threshold. custom uses the
# stored custom value; unknown/empty falls back to tolerant. Mirrors the poller
# resolve_quality_thresholds() mapping (see docs/features/connection-quality.md).
resolve_latency_ms() {
    local preset="$1"
    local custom="$2"
    case "$preset" in
        standard)      echo 150 ;;
        tolerant)      echo 250 ;;
        very-tolerant) echo 500 ;;
        custom)
            case "$custom" in
                ''|*[!0-9]*) echo 250 ;;
                *) echo "$custom" ;;
            esac
            ;;
        *) echo 250 ;;
    esac
}

# Resolve a quality preset (loss) to a numeric pct threshold.
resolve_loss_pct() {
    local preset="$1"
    local custom="$2"
    case "$preset" in
        standard)      echo 15 ;;
        tolerant)      echo 30 ;;
        very-tolerant) echo 50 ;;
        custom)
            case "$custom" in
                ''|*[!0-9]*) echo 30 ;;
                *) echo "$custom" ;;
            esac
            ;;
        *) echo 30 ;;
    esac
}

# Validate numeric field: returns 0 if valid int in [min,max], else 1
validate_int() {
    local val="$1"
    local min="$2"
    local max="$3"
    case "$val" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$val" -ge "$min" ] 2>/dev/null && [ "$val" -le "$max" ] 2>/dev/null
}

# Reject the request with a structured error and exit.
# Frontend checks .success === false; HTTP status remains 200 (headers
# already emitted by cgi_headers at file top — project convention).
reject_field() {
    local field="$1"
    local reason="$2"
    # Drop everything this request staged so a rejected save cannot be
    # committed later by an unrelated uci commit.
    uci -q revert quecmanager 2>/dev/null
    jq -n --arg field "$field" --arg reason "$reason" \
        '{success:false, error:"invalid_field", field:$field, reason:$reason}'
    exit 0
}

# =============================================================================
# GET — Fetch settings + live status
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Fetching watchdog settings"
    ensure_watchcat_config

    enabled="" fail_threshold="" check_interval="" cooldown=""
    tier1="" tier2="" tier3="" tier4="" backup_sim="" max_reboots=""
    quality_enabled="" quality_consecutive=""
    ssr_aware="" ssr_grace=""
    primary_recheck_enabled="" primary_recheck_interval=""

    enabled=$(uci_get enabled 0)
    fail_threshold=$(uci_get fail_threshold 5)
    check_interval=$(uci_get check_interval 10)
    cooldown=$(uci_get cooldown 60)
    tier1=$(uci_get tier1_enabled 1)
    tier2=$(uci_get tier2_enabled 1)
    tier3=$(uci_get tier3_enabled 0)
    tier4=$(uci_get tier4_enabled 1)
    backup_sim=$(uci_get backup_sim_slot "")
    max_reboots=$(uci_get max_reboots_per_hour 3)
    quality_enabled=$(uci_get quality_enabled 0)
    quality_consecutive=$(uci_get quality_consecutive 5)
    ssr_aware=$(uci_get ssr_aware 1)
    ssr_grace=$(uci_get ssr_grace 45)
    primary_recheck_enabled=$(uci_get primary_recheck_enabled 0)
    primary_recheck_interval=$(uci_get primary_recheck_interval 30)

    # Every value below goes through jq --argjson: coerce to the default.
    enabled=$(coerce_bool "$enabled" 0)
    fail_threshold=$(coerce_int "$fail_threshold" 5)
    check_interval=$(coerce_int "$check_interval" 10)
    cooldown=$(coerce_int "$cooldown" 60)
    tier1=$(coerce_bool "$tier1" 1)
    tier2=$(coerce_bool "$tier2" 1)
    tier3=$(coerce_bool "$tier3" 0)
    tier4=$(coerce_bool "$tier4" 1)
    max_reboots=$(coerce_int "$max_reboots" 3)
    quality_enabled=$(coerce_bool "$quality_enabled" 0)
    quality_consecutive=$(coerce_int "$quality_consecutive" 5)
    ssr_aware=$(coerce_bool "$ssr_aware" 1)
    ssr_grace=$(coerce_int "$ssr_grace" 45)
    primary_recheck_enabled=$(coerce_bool "$primary_recheck_enabled" 0)
    primary_recheck_interval=$(coerce_int "$primary_recheck_interval" 30)
    case "$backup_sim" in
        1|2) ;;
        *) backup_sim="" ;;
    esac

    # --- Probe interval reflection (ping_profile section, read-only mirror) ---
    probe_profile=""
    interval_override=""
    effective_interval=""
    probe_profile=$(uci -q get quecmanager.ping_profile.profile 2>/dev/null)
    [ -z "$probe_profile" ] && probe_profile="relaxed"
    interval_override=$(uci -q get quecmanager.ping_profile.interval_override 2>/dev/null)
    # Effective cadence from UCI (right even while the daemon is down).
    conn_state_cadence
    effective_interval="$CQ_CFG_INTERVAL_SEC"

    # --- Shared quality thresholds (read-only mirror of quality_thresholds) ---
    qt_latency_preset=""
    qt_loss_preset=""
    qt_latency_custom=""
    qt_loss_custom=""
    if uci -q get quecmanager.quality_thresholds >/dev/null 2>&1; then
        qt_latency_preset=$(uci -q get quecmanager.quality_thresholds.latency_preset 2>/dev/null)
        qt_loss_preset=$(uci -q get quecmanager.quality_thresholds.loss_preset 2>/dev/null)
        qt_latency_custom=$(uci -q get quecmanager.quality_thresholds.latency_custom_ms 2>/dev/null)
        qt_loss_custom=$(uci -q get quecmanager.quality_thresholds.loss_custom_pct 2>/dev/null)
    fi
    [ -z "$qt_latency_preset" ] && qt_latency_preset="tolerant"
    [ -z "$qt_loss_preset" ] && qt_loss_preset="tolerant"
    qt_latency_ms=$(resolve_latency_ms "$qt_latency_preset" "$qt_latency_custom")
    qt_loss_pct=$(resolve_loss_pct "$qt_loss_preset" "$qt_loss_custom")

    # Read live status from watchcat daemon state file
    # (a 0-byte or half-written file falls back to the default, never a 500)
    status_json='{}'
    if [ -f "$WATCHCAT_STATE" ]; then
        status_json=$(json_or_default object "$(cat "$WATCHCAT_STATE" 2>/dev/null)" '{}')
    fi

    # Read SIM failover state
    sim_failover_json='{"active":false}'
    if [ -f "$SIM_FAILOVER_FILE" ]; then
        sim_failover_json=$(json_or_default object "$(cat "$SIM_FAILOVER_FILE" 2>/dev/null)" '{"active":false}')
    fi

    # Read SIM swap detection
    sim_swap_json='{"detected":false}'
    if [ -f "$SIM_SWAP_FLAG" ]; then
        sim_swap_json=$(json_or_default object "$(cat "$SIM_SWAP_FLAG" 2>/dev/null)" '{"detected":false}')
    fi

    # Recent watchdog reboots: epoch ints, newest first, at most 5.
    recent_reboots_json=$(json_or_default array "$(wd_ledger_recent_json 5 2>/dev/null)" '[]')

    # Check if watchcat was auto-disabled
    auto_disabled="false"
    [ -f "$DISABLED_FLAG" ] && auto_disabled="true"

    # interval_override: emit JSON null when unset/non-numeric, else the int.
    interval_override_json=$(coerce_int "$interval_override" null)
    effective_interval=$(coerce_int "$effective_interval" 5)
    CQ_CFG_INTERVAL_SEC=$(coerce_int "$CQ_CFG_INTERVAL_SEC" 5)
    CQ_CFG_FAIL_SECS=$(coerce_int "$CQ_CFG_FAIL_SECS" 15)
    CQ_CFG_RECOVER_SECS=$(coerce_int "$CQ_CFG_RECOVER_SECS" 10)
    qt_latency_ms=$(coerce_int "$qt_latency_ms" 250)
    qt_loss_pct=$(coerce_int "$qt_loss_pct" 30)

    jq -n \
        --argjson enabled "$enabled" \
        --argjson fail_threshold "$fail_threshold" \
        --argjson check_interval "$check_interval" \
        --argjson cooldown "$cooldown" \
        --argjson tier1 "$tier1" \
        --argjson tier2 "$tier2" \
        --argjson tier3 "$tier3" \
        --argjson tier4 "$tier4" \
        --arg backup_sim "$backup_sim" \
        --argjson max_reboots "$max_reboots" \
        --argjson quality_enabled "$quality_enabled" \
        --argjson quality_consecutive "$quality_consecutive" \
        --argjson ssr_aware "$ssr_aware" \
        --argjson ssr_grace "$ssr_grace" \
        --argjson primary_recheck_enabled "$primary_recheck_enabled" \
        --argjson primary_recheck_interval "$primary_recheck_interval" \
        --arg probe_profile "$probe_profile" \
        --argjson interval_override "$interval_override_json" \
        --argjson effective_interval "$effective_interval" \
        --argjson interval_sec "$CQ_CFG_INTERVAL_SEC" \
        --argjson fail_secs "$CQ_CFG_FAIL_SECS" \
        --argjson recover_secs "$CQ_CFG_RECOVER_SECS" \
        --argjson qt_latency_ms "$qt_latency_ms" \
        --argjson qt_loss_pct "$qt_loss_pct" \
        --arg qt_latency_preset "$qt_latency_preset" \
        --arg qt_loss_preset "$qt_loss_preset" \
        --argjson status "$status_json" \
        --argjson sim_failover "$sim_failover_json" \
        --argjson sim_swap "$sim_swap_json" \
        --argjson auto_disabled "$auto_disabled" \
        --argjson recent_reboots "$recent_reboots_json" \
        '{
            success: true,
            settings: {
                enabled: ($enabled == 1),
                fail_threshold: $fail_threshold,
                check_interval: $check_interval,
                cooldown: $cooldown,
                tier1_enabled: ($tier1 == 1),
                tier2_enabled: ($tier2 == 1),
                tier3_enabled: ($tier3 == 1),
                tier4_enabled: ($tier4 == 1),
                backup_sim_slot: (if $backup_sim == "" then null else ($backup_sim | tonumber) end),
                max_reboots_per_hour: $max_reboots,
                quality_enabled: ($quality_enabled == 1),
                quality_consecutive: $quality_consecutive,
                ssr_aware: ($ssr_aware == 1),
                ssr_grace: $ssr_grace,
                primary_recheck_enabled: ($primary_recheck_enabled == 1),
                primary_recheck_interval: $primary_recheck_interval
            },
            probe_profile: $probe_profile,
            interval_override: $interval_override,
            effective_interval: $effective_interval,
            interval_sec: $interval_sec,
            fail_secs: $fail_secs,
            recover_secs: $recover_secs,
            quality_thresholds: {
                latency_ms: $qt_latency_ms,
                loss_pct: $qt_loss_pct,
                latency_preset: $qt_latency_preset,
                loss_preset: $qt_loss_preset
            },
            status: $status,
            sim_failover: $sim_failover,
            sim_swap: $sim_swap,
            auto_disabled: $auto_disabled,
            recent_reboots: $recent_reboots
        }'
    exit 0
fi

# =============================================================================
# POST — Save settings / dismiss SIM swap / revert SIM
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty')

    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: save_settings
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "save_settings" ]; then
        qlog_info "Saving watchdog settings"
        ensure_watchcat_config

        # Extract fields from POST body
        val=""

        val=$(printf '%s' "$POST_DATA" | jq -r '.enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in
                true) uci set quecmanager.watchcat.enabled=1 ;;
                false) uci set quecmanager.watchcat.enabled=0 ;;
            esac
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.fail_threshold | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            validate_int "$val" 1 20 || reject_field "fail_threshold" "must be integer 1-20"
            uci set quecmanager.watchcat.fail_threshold="$val"
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.check_interval | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            validate_int "$val" 5 60 || reject_field "check_interval" "must be integer 5-60"
            uci set quecmanager.watchcat.check_interval="$val"
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.cooldown | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            validate_int "$val" 10 300 || reject_field "cooldown" "must be integer 10-300"
            uci set quecmanager.watchcat.cooldown="$val"
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.tier1_enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in true) uci set quecmanager.watchcat.tier1_enabled=1 ;; false) uci set quecmanager.watchcat.tier1_enabled=0 ;; esac
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.tier2_enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in true) uci set quecmanager.watchcat.tier2_enabled=1 ;; false) uci set quecmanager.watchcat.tier2_enabled=0 ;; esac
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.tier3_enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in true) uci set quecmanager.watchcat.tier3_enabled=1 ;; false) uci set quecmanager.watchcat.tier3_enabled=0 ;; esac
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.tier4_enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in true) uci set quecmanager.watchcat.tier4_enabled=1 ;; false) uci set quecmanager.watchcat.tier4_enabled=0 ;; esac
        fi

        # backup_sim_slot: present + 1/2 => set; present + null/empty => clear;
        # absent => untouched, so a save from one card never wipes the slot.
        has_slot=$(printf '%s' "$POST_DATA" | jq -r 'has("backup_sim_slot")')
        if [ "$has_slot" = "true" ]; then
            val=$(printf '%s' "$POST_DATA" | jq -r '.backup_sim_slot | if . == null then empty else tostring end')
            case "$val" in
                '') uci set quecmanager.watchcat.backup_sim_slot="" ;;
                1|2) uci set quecmanager.watchcat.backup_sim_slot="$val" ;;
                *) reject_field "backup_sim_slot" "must be 1 or 2" ;;
            esac
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.max_reboots_per_hour | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            validate_int "$val" 1 10 || reject_field "max_reboots_per_hour" "must be integer 1-10"
            uci set quecmanager.watchcat.max_reboots_per_hour="$val"
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.quality_enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in true) uci set quecmanager.watchcat.quality_enabled=1 ;; false) uci set quecmanager.watchcat.quality_enabled=0 ;; esac
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.quality_consecutive | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            validate_int "$val" 1 60 || reject_field "quality_consecutive" "must be integer 1-60"
            uci set quecmanager.watchcat.quality_consecutive="$val"
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.ssr_grace | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            validate_int "$val" 10 120 || reject_field "ssr_grace" "must be integer 10-120"
            uci set quecmanager.watchcat.ssr_grace="$val"
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.ssr_aware | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in true) uci set quecmanager.watchcat.ssr_aware=1 ;; false) uci set quecmanager.watchcat.ssr_aware=0 ;; esac
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.primary_recheck_enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in true) uci set quecmanager.watchcat.primary_recheck_enabled=1 ;; false) uci set quecmanager.watchcat.primary_recheck_enabled=0 ;; esac
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.primary_recheck_interval | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            validate_int "$val" 5 1440 || reject_field "primary_recheck_interval" "must be integer 5-1440"
            uci set quecmanager.watchcat.primary_recheck_interval="$val"
        fi

        # ---------------------------------------------------------------------
        # Probe interval (ping_profile section). The Watchdog page is the single
        # writer for the Custom interval override; the Sensitivity page only
        # reflects it (one owner avoids a two-writer race). These writes target
        # quecmanager.ping_profile.*, NOT watchcat.*.
        # ---------------------------------------------------------------------
        ping_profile_changed=0

        val=$(printf '%s' "$POST_DATA" | jq -r '.probe_profile // empty')
        if [ -n "$val" ]; then
            case "$val" in
                sensitive|regular|relaxed|quiet)
                    # Ensure the section exists before writing into it.
                    uci -q get quecmanager.ping_profile >/dev/null 2>&1 || \
                        uci set quecmanager.ping_profile=ping_profile
                    uci set quecmanager.ping_profile.profile="$val"
                    ping_profile_changed=1
                    ;;
                *) reject_field "probe_profile" "must be one of: sensitive, regular, relaxed, quiet" ;;
            esac
        fi

        # interval_override: present + null/empty => clear; present + int => set
        # (range 1-60); absent => leave untouched. We distinguish "key absent"
        # from "key present but null" so the page can explicitly clear.
        has_override=$(printf '%s' "$POST_DATA" | jq -r 'has("interval_override")')
        if [ "$has_override" = "true" ]; then
            val=$(printf '%s' "$POST_DATA" | jq -r '.interval_override | if . == null then empty else tostring end')
            uci -q get quecmanager.ping_profile >/dev/null 2>&1 || \
                uci set quecmanager.ping_profile=ping_profile
            if [ -z "$val" ]; then
                # Explicit clear (null or empty string).
                uci -q delete quecmanager.ping_profile.interval_override 2>/dev/null
            else
                validate_int "$val" 1 60 || reject_field "interval_override" "must be integer 1-60"
                uci set quecmanager.ping_profile.interval_override="$val"
            fi
            ping_profile_changed=1
        fi

        # probe_interval: the effective ping cadence in seconds (Detection card).
        # Ignored when interval_override is also sent. An unchanged value writes
        # nothing, so a Ladder-card save never touches cadence; a changed value
        # sets the override, or clears it when it equals the profile's own interval.
        val=$(printf '%s' "$POST_DATA" | jq -r '.probe_interval | if . == null then empty else tostring end')
        if [ -n "$val" ] && [ "$has_override" != "true" ]; then
            validate_int "$val" 1 60 || reject_field "probe_interval" "must be integer 1-60"
            conn_state_cadence
            if [ "$val" != "$CQ_CFG_INTERVAL_SEC" ]; then
                uci -q get quecmanager.ping_profile >/dev/null 2>&1 ||                     uci set quecmanager.ping_profile=ping_profile
                if [ "$val" = "$CQ_CFG_PROFILE_INTERVAL_SEC" ]; then
                    uci -q delete quecmanager.ping_profile.interval_override 2>/dev/null
                else
                    uci set quecmanager.ping_profile.interval_override="$val"
                fi
                ping_profile_changed=1
            fi
        fi

        uci commit quecmanager

        # Signal running watchcat daemon to reload config (if it's already running)
        touch "$RELOAD_FLAG"

        # If any ping_profile field changed, signal the ping daemon too.
        if [ "$ping_profile_changed" = "1" ]; then
            touch "$PING_RELOAD_FLAG"
        fi

        # Clear auto-disabled flag if user is re-enabling
        new_enabled=""
        new_enabled=$(uci -q get quecmanager.watchcat.enabled 2>/dev/null)
        if [ "$new_enabled" = "1" ]; then
            rm -f "$DISABLED_FLAG"
            # Enable on boot. A running daemon picks the change up from the
            # reload flag touched above, so only start it when it is down
            # (a restart would drop the live recovery state mid-save).
            /etc/init.d/qmanager_watchcat enable 2>/dev/null
            if /etc/init.d/qmanager_watchcat running >/dev/null 2>&1; then
                qlog_info "Watchdog settings saved, running watchcat will reload"
            else
                ( /etc/init.d/qmanager_watchcat start >/dev/null 2>&1 & )
                qlog_info "Watchdog settings saved, watchcat enabled and started"
            fi
        else
            # Stop and disable the watchcat init script
            /etc/init.d/qmanager_watchcat stop >/dev/null 2>&1
            /etc/init.d/qmanager_watchcat disable 2>/dev/null
            qlog_info "Watchdog settings saved, watchcat stopped and disabled"
        fi
        echo '{"success":true}'
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: dismiss_sim_swap
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "dismiss_sim_swap" ]; then
        qlog_info "Dismissing SIM swap notification"
        if [ -f "$SIM_SWAP_FLAG" ]; then
            tmp_json=$(jq -c '.dismissed = true' "$SIM_SWAP_FLAG" 2>/dev/null)
            if [ -n "$tmp_json" ]; then
                # B4.1: root-owned rewrite, not write-through of a planted file
                printf '%s\n' "$tmp_json" | qm_atomic_write "$SIM_SWAP_FLAG"
            fi
        fi
        echo '{"success":true}'
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: revert_sim
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "revert_sim" ]; then
        qlog_info "User requesting SIM revert"
        # B4.1: root-owned flag (the daemon ignores any other)
        : | qm_atomic_write "$REVERT_FLAG"
        echo '{"success":true,"message":"SIM revert requested. The watchcat will process this shortly."}'
        exit 0
    fi

    # Unknown action
    cgi_error "unknown_action" "Unknown action: $ACTION"
    exit 0
fi

# Method not allowed
cgi_error "method_not_allowed" "Only GET and POST are supported"
