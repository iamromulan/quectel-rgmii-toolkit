#!/bin/sh
# =============================================================================
# wd_config.sh - qmanager_watchcat: UCI configuration and fixed constants
# =============================================================================
# Sourced by qmanager_watchcat (never executed). BusyBox ash safe.
#
# Owns (declared and initialised here, see docs/plans watchdog-modular-lean 2.1):
#   every CFG_* global, BOOT_SETTLE,
#   MODEM_WAIT_TIMEOUT, SIM_SETTLE_SECS, HOLDOFF_SECS
# Functions: read_config, resolve_quality_thresholds
#
# Libraries hold function definitions and global initialisers only: no top-level
# commands and no sourcing of other libs. The last line sets WD_CONFIG_LOADED so
# the daemon can refuse to start on a half-loaded library set.
# =============================================================================

# --- Configuration (defaults, overridden by UCI) -----------------------------
CFG_ENABLED=0
CFG_CHECK_INTERVAL=10
CFG_FAIL_THRESHOLD=5          # consecutive failed PROBES (raw ping streak_fail) before recovery
CFG_COOLDOWN=60
CFG_TIER1_ENABLED=1
CFG_TIER2_ENABLED=1
CFG_TIER3_ENABLED=0
CFG_TIER4_ENABLED=1
CFG_BACKUP_SIM_SLOT=""
CFG_MAX_REBOOTS_PER_HOUR=3
CFG_QUALITY_ENABLED=0
# Shared degraded thresholds resolved from quecmanager.quality_thresholds.*
# (NOT watchcat.* — the retired latency_ceiling_ms/loss_ceiling_pct keys). These
# are recomputed by resolve_quality_thresholds() on each config load/reload.
CFG_LATENCY_THRESHOLD_MS=250
CFG_LOSS_THRESHOLD_PCT=30
CFG_QUALITY_CONSECUTIVE=5
CFG_SSR_AWARE=1
CFG_SSR_GRACE=45
# Auto-failback to the primary SIM after a Tier-3 failover. The inactive primary
# slot CANNOT be passively health-checked (single hard SIM mux), so failback is a
# BLIND periodic swap-back-to-primary + retest — each attempt is a real outage.
# OPT-IN, default OFF. Interval is in MINUTES (a seconds cadence would be ruinous).
CFG_PRIMARY_RECHECK_ENABLED=0
CFG_PRIMARY_RECHECK_INTERVAL=30
BOOT_SETTLE=30
# Ping-cache staleness is conn_state_read's rule: max(3 * interval_sec, 15) s.
MODEM_WAIT_TIMEOUT=60
# A physical SIM swap on the RM551E needs ~90s to reach stable connectivity.
# Any Tier-3 (SIM-failover) recovery — and the reverse revert swap — must hold
# this floor before the first success/connectivity evaluation, otherwise the
# generic cooldown fires the success ping while the modem is still attaching and
# false-fails a swap that was actually fine. FIXED floor by design (not UCI).
SIM_SETTLE_SECS=90
# Pause after every enabled tier has been tried without restoring connectivity
# (fixed, not UCI): wd_decide_start returns "holdoff" until it elapses.
HOLDOFF_SECS=900

# =============================================================================
# CONFIGURATION
# =============================================================================

read_config() {
    CFG_ENABLED=$(uci -q get quecmanager.watchcat.enabled 2>/dev/null)
    [ -z "$CFG_ENABLED" ] && CFG_ENABLED=0

    local val
    val=$(uci -q get quecmanager.watchcat.check_interval 2>/dev/null)
    [ -n "$val" ] && CFG_CHECK_INTERVAL="$val"

    # fail_threshold = consecutive failed PROBES (raw ping streak_fail). Renamed
    # from the retired max_failures (which counted watchcat's own loop cycles).
    # Default 5 if absent so an un-migrated install still works immediately.
    val=$(uci -q get quecmanager.watchcat.fail_threshold 2>/dev/null)
    case "$val" in ''|*[!0-9]*) CFG_FAIL_THRESHOLD=5 ;; *) CFG_FAIL_THRESHOLD="$val" ;; esac

    val=$(uci -q get quecmanager.watchcat.cooldown 2>/dev/null)
    [ -n "$val" ] && CFG_COOLDOWN="$val"

    val=$(uci -q get quecmanager.watchcat.tier1_enabled 2>/dev/null)
    [ -n "$val" ] && CFG_TIER1_ENABLED="$val"

    val=$(uci -q get quecmanager.watchcat.tier2_enabled 2>/dev/null)
    [ -n "$val" ] && CFG_TIER2_ENABLED="$val"

    val=$(uci -q get quecmanager.watchcat.tier3_enabled 2>/dev/null)
    [ -n "$val" ] && CFG_TIER3_ENABLED="$val"

    val=$(uci -q get quecmanager.watchcat.tier4_enabled 2>/dev/null)
    [ -n "$val" ] && CFG_TIER4_ENABLED="$val"

    val=$(uci -q get quecmanager.watchcat.backup_sim_slot 2>/dev/null)
    CFG_BACKUP_SIM_SLOT="$val"

    val=$(uci -q get quecmanager.watchcat.max_reboots_per_hour 2>/dev/null)
    [ -n "$val" ] && CFG_MAX_REBOOTS_PER_HOUR="$val"

    CFG_QUALITY_ENABLED=$(uci -q get quecmanager.watchcat.quality_enabled 2>/dev/null)
    [ -z "$CFG_QUALITY_ENABLED" ] && CFG_QUALITY_ENABLED=0

    # Degraded thresholds are now SHARED with the poller: read from
    # quecmanager.quality_thresholds.* (latency_ceiling_ms / loss_ceiling_pct on
    # watchcat.* are retired and intentionally NOT read here).
    resolve_quality_thresholds

    val=$(uci -q get quecmanager.watchcat.quality_consecutive 2>/dev/null)
    [ -n "$val" ] && CFG_QUALITY_CONSECUTIVE="$val"

    CFG_SSR_AWARE=$(uci -q get quecmanager.watchcat.ssr_aware 2>/dev/null)
    [ -z "$CFG_SSR_AWARE" ] && CFG_SSR_AWARE=1

    val=$(uci -q get quecmanager.watchcat.ssr_grace 2>/dev/null)
    [ -n "$val" ] && CFG_SSR_GRACE="$val"

    CFG_PRIMARY_RECHECK_ENABLED=$(uci -q get quecmanager.watchcat.primary_recheck_enabled 2>/dev/null)
    [ -z "$CFG_PRIMARY_RECHECK_ENABLED" ] && CFG_PRIMARY_RECHECK_ENABLED=0

    # interval is in MINUTES; non-numeric/empty falls back to 30.
    val=$(uci -q get quecmanager.watchcat.primary_recheck_interval 2>/dev/null)
    case "$val" in ''|*[!0-9]*) CFG_PRIMARY_RECHECK_INTERVAL=30 ;; *) CFG_PRIMARY_RECHECK_INTERVAL="$val" ;; esac

    qlog_info "Config loaded: interval=${CFG_CHECK_INTERVAL}s fail_threshold=${CFG_FAIL_THRESHOLD} probes cooldown=${CFG_COOLDOWN}s"
    qlog_info "  Tiers: T1=${CFG_TIER1_ENABLED} T2=${CFG_TIER2_ENABLED} T3=${CFG_TIER3_ENABLED} T4=${CFG_TIER4_ENABLED} backup_sim=${CFG_BACKUP_SIM_SLOT:-none}"
    qlog_info "  Quality: enabled=${CFG_QUALITY_ENABLED} latency=${CFG_LATENCY_THRESHOLD_MS}ms loss=${CFG_LOSS_THRESHOLD_PCT}% consecutive=${CFG_QUALITY_CONSECUTIVE} (shared thresholds)"
    qlog_info "  SSR-aware: enabled=${CFG_SSR_AWARE} grace=${CFG_SSR_GRACE}s"
    qlog_info "  Primary-recheck (auto-failback): enabled=${CFG_PRIMARY_RECHECK_ENABLED} interval=${CFG_PRIMARY_RECHECK_INTERVAL}min"
}

# Resolve the SHARED degraded thresholds from quecmanager.quality_thresholds.*
# into CFG_LATENCY_THRESHOLD_MS / CFG_LOSS_THRESHOLD_PCT. This is the watchdog's
# local mirror of the poller's resolver (kept in-daemon rather than a new lib —
# only two consumers, and the watchdog must not depend on poller globals). The
# section's ABSENCE means "default" -> tolerant/tolerant (250ms / 30%), matching
# the poller. `custom` reads the latency_custom_ms / loss_custom_pct keys; a
# non-numeric/empty custom value falls back to the tolerant default so a
# half-written UCI never yields an empty comparison value.
resolve_quality_thresholds() {
    local _lat_preset
    local _loss_preset
    local _lat_custom
    local _loss_custom

    _lat_preset=$(uci -q get quecmanager.quality_thresholds.latency_preset 2>/dev/null)
    _loss_preset=$(uci -q get quecmanager.quality_thresholds.loss_preset 2>/dev/null)

    case "$_lat_preset" in
        standard)      CFG_LATENCY_THRESHOLD_MS=150 ;;
        very-tolerant) CFG_LATENCY_THRESHOLD_MS=500 ;;
        custom)
            _lat_custom=$(uci -q get quecmanager.quality_thresholds.latency_custom_ms 2>/dev/null)
            case "$_lat_custom" in
                ''|*[!0-9]*) CFG_LATENCY_THRESHOLD_MS=250 ;;
                *)           CFG_LATENCY_THRESHOLD_MS="$_lat_custom" ;;
            esac
            ;;
        tolerant|*)    CFG_LATENCY_THRESHOLD_MS=250 ;;
    esac

    case "$_loss_preset" in
        standard)      CFG_LOSS_THRESHOLD_PCT=15 ;;
        very-tolerant) CFG_LOSS_THRESHOLD_PCT=50 ;;
        custom)
            _loss_custom=$(uci -q get quecmanager.quality_thresholds.loss_custom_pct 2>/dev/null)
            case "$_loss_custom" in
                ''|*[!0-9]*) CFG_LOSS_THRESHOLD_PCT=30 ;;
                *)           CFG_LOSS_THRESHOLD_PCT="$_loss_custom" ;;
            esac
            ;;
        tolerant|*)    CFG_LOSS_THRESHOLD_PCT=30 ;;
    esac
}

WD_CONFIG_LOADED=1
