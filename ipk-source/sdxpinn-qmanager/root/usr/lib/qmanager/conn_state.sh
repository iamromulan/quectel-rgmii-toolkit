#!/bin/sh
# =============================================================================
# conn_state.sh — the one reader of the ping daemon's cache + cadence resolver
# =============================================================================
# Sourced (never executed) by qmanager_poller, qmanager_watchcat, qmanager_ping
# and the ping_profile / watchdog CGIs. POSIX sh / BusyBox ash safe; jq is used
# without regex (the device jq has no Oniguruma).
#
#   conn_state_read     one jq read of /tmp/qmanager_ping.json into CQ_* vars,
#                       with the single staleness rule. Fail-closed: any
#                       problem leaves CQ_STALE=1 and CQ_REACHABLE="null"
#                       (unknown — never treated as down or as up).
#   conn_state_why      reason for the last stale/failed read (for logs)
#   conn_state_is_up    fresh read with reachable=true
#   conn_state_resolve  profile name + override -> cadence (pure, no UCI)
#   conn_state_cadence  same, reading quecmanager.ping_profile.* from UCI
#   cq_alert_after_min  the single alert wait (minutes) into CQ_ALERT_AFTER_MIN
#
# All helper state is global and prefixed _cq_ (no `local`, so it can be
# called from any scope).
# =============================================================================

[ -n "${_CONN_STATE_LOADED:-}" ] && return 0
_CONN_STATE_LOADED=1

CQ_PING_CACHE="${CQ_PING_CACHE:-/tmp/qmanager_ping.json}"
_CQ_TAB=$(printf '\t')

# Neutral values for a stale / missing / unreadable cache.
_cq_reset() {
    CQ_STALE=1
    CQ_STALE_REASON=""
    CQ_AGE_SEC=""
    CQ_STALE_THRESHOLD=15
    CQ_TIMESTAMP=""
    CQ_MONO=""
    CQ_REACHABLE="null"
    CQ_RTT_MS="null"
    CQ_STREAK_SUCCESS=0
    CQ_STREAK_FAIL=0
    CQ_DURING_RECOVERY="false"
    CQ_INTERVAL_SEC=5
    CQ_PROFILE=""
    CQ_LAST_FAMILY=""
    CQ_TARGET=""
    CQ_FAIL_SECS=""
    CQ_RECOVER_SECS=""
}
_cq_reset

# conn_state_read: returns 0 when the cache is fresh, 1 when it is stale,
# missing or unreadable (verdict vars are then the neutral values above).
# Stale = age > max(3 * interval_sec, 15); interval_sec outside 1-300 is
# clamped to 5. Age comes from the cache `mono` against /proc/uptime; the wall
# clock (date +%s - timestamp) is used only when mono is absent or 0, because
# NITZ/NTP steps the wall clock. mono ahead of uptime cannot come from this
# boot's daemon (/tmp is tmpfs), so it is treated as garbage = stale.
conn_state_read() {
    _cq_reset
    if [ ! -f "$CQ_PING_CACHE" ]; then
        CQ_STALE_REASON="missing"
        return 1
    fi

    # "-" stands in for empty/null: IFS whitespace (tab) collapses empty fields.
    _cq_row=$(jq -r 'def s: if . == null or . == "" then "-" else tostring end;
        [(.timestamp|s), (.mono|s), (.reachable|s), (.last_rtt_ms|s),
         (.streak_success|s), (.streak_fail|s), (.during_recovery|s),
         (.interval_sec|s), (.fail_secs|s), (.recover_secs|s), (.profile|s),
         (.last_family|s), ((.targets // [])[0]|s)] | @tsv' \
        "$CQ_PING_CACHE" 2>/dev/null </dev/null)
    if [ -z "$_cq_row" ]; then
        CQ_STALE_REASON="unreadable"
        return 1
    fi

    IFS="$_CQ_TAB" read -r _cq_ts _cq_mono _cq_reach _cq_rtt _cq_ss _cq_sf _cq_dr \
        _cq_iv _cq_fs _cq_rs _cq_prof _cq_fam _cq_tgt <<EOF
$_cq_row
EOF

    case "$_cq_ts" in
        ''|*[!0-9]*)
            CQ_STALE_REASON="no timestamp"
            return 1
            ;;
    esac

    case "$_cq_iv" in ''|*[!0-9]*) _cq_iv=5 ;; esac
    if [ "$_cq_iv" -lt 1 ] || [ "$_cq_iv" -gt 300 ]; then
        _cq_iv=5
    fi
    CQ_INTERVAL_SEC="$_cq_iv"
    CQ_STALE_THRESHOLD=$((3 * _cq_iv))
    [ "$CQ_STALE_THRESHOLD" -lt 15 ] && CQ_STALE_THRESHOLD=15

    _cq_age=""
    case "$_cq_mono" in
        ''|*[!0-9]*|0) ;;
        *)
            _cq_up=""
            { read -r _cq_up _cq_idle < /proc/uptime; } 2>/dev/null
            _cq_up="${_cq_up%%.*}"
            case "$_cq_up" in
                ''|*[!0-9]*) ;;
                *)
                    CQ_MONO="$_cq_mono"
                    _cq_age=$((_cq_up - _cq_mono))
                    if [ "$_cq_age" -lt 0 ]; then
                        CQ_AGE_SEC="$_cq_age"
                        CQ_STALE_REASON="mono ahead of uptime"
                        return 1
                    fi
                    ;;
            esac
            ;;
    esac
    [ -z "$_cq_age" ] && _cq_age=$(( $(date +%s) - _cq_ts ))
    CQ_AGE_SEC="$_cq_age"
    if [ "$_cq_age" -gt "$CQ_STALE_THRESHOLD" ]; then
        CQ_STALE_REASON="age ${_cq_age}s > ${CQ_STALE_THRESHOLD}s"
        return 1
    fi

    CQ_STALE=0
    CQ_TIMESTAMP="$_cq_ts"
    case "$_cq_reach" in true|false) CQ_REACHABLE="$_cq_reach" ;; esac
    case "$_cq_rtt" in ''|-|*[!0-9.]*) ;; *) CQ_RTT_MS="$_cq_rtt" ;; esac
    case "$_cq_ss" in ''|*[!0-9]*) ;; *) CQ_STREAK_SUCCESS="$_cq_ss" ;; esac
    case "$_cq_sf" in ''|*[!0-9]*) ;; *) CQ_STREAK_FAIL="$_cq_sf" ;; esac
    [ "$_cq_dr" = "true" ] && CQ_DURING_RECOVERY="true"
    case "$_cq_fs" in ''|*[!0-9]*) ;; *) CQ_FAIL_SECS="$_cq_fs" ;; esac
    case "$_cq_rs" in ''|*[!0-9]*) ;; *) CQ_RECOVER_SECS="$_cq_rs" ;; esac
    [ "$_cq_prof" != "-" ] && CQ_PROFILE="$_cq_prof"
    [ "$_cq_fam" != "-" ] && CQ_LAST_FAMILY="$_cq_fam"
    [ "$_cq_tgt" != "-" ] && CQ_TARGET="$_cq_tgt"
    return 0
}

# ---------------------------------------------------------------------------
# Sidecar reader (B5.29 Phase C). qmanager_ping also writes the 13 raw fields
# conn_state_read extracts with jq to /var/run/qmanager/ping.env (shell
# assignments, tmp + mv, written after ping.json). The poller reads that with
# builtins instead of forking jq every cycle. conn_state_read above is
# unchanged and stays the watchcat's reader.
# ---------------------------------------------------------------------------
CQ_PING_ENV="${CQ_PING_ENV:-/var/run/qmanager/ping.env}"

# cq_env_source <file>: source a sidecar only if it is complete and plain.
# Every line must be a single-quoted assignment and the last must be the end
# marker. A BusyBox syntax error in a dot-sourced file aborts the whole script,
# so anything else returns 1 without sourcing.
cq_env_source() {
    _ces_last=""
    _ces_bad=0
    [ -f "$1" ] || return 1
    {
        while IFS= read -r _ces_l; do
            case "$_ces_l" in
                [A-Za-z_]*=\'*\') ;;
                *) _ces_bad=1 ;;
            esac
            _ces_last="$_ces_l"
        done < "$1"
    } 2>/dev/null
    [ "$_ces_bad" = "0" ] || return 1
    [ "$_ces_last" = "qm_sidecar_end='1'" ] || return 1
    . "$1"
}

# conn_state_read_env: conn_state_read from the sidecar. Same contract and same
# CQ_* results; returns 2 (nothing read, nothing changed) when the sidecar is
# absent, older than ping.json (upgrade window, daemon not restarted, failed
# write) or incomplete, so the caller falls back to conn_state_read. The
# evaluation below must stay in lockstep with conn_state_read.
conn_state_read_env() {
    [ -f "$CQ_PING_CACHE" ] || return 2
    [ -f "$CQ_PING_ENV" ] || return 2
    [ "$CQ_PING_CACHE" -nt "$CQ_PING_ENV" ] && return 2
    _cq_ts=""; _cq_mono=""; _cq_reach=""; _cq_rtt=""; _cq_ss=""; _cq_sf=""
    _cq_dr=""; _cq_iv=""; _cq_fs=""; _cq_rs=""; _cq_prof=""; _cq_fam=""; _cq_tgt=""
    cq_env_source "$CQ_PING_ENV" || return 2
    _cq_reset

    case "$_cq_ts" in
        ''|*[!0-9]*)
            CQ_STALE_REASON="no timestamp"
            return 1
            ;;
    esac

    case "$_cq_iv" in ''|*[!0-9]*) _cq_iv=5 ;; esac
    if [ "$_cq_iv" -lt 1 ] || [ "$_cq_iv" -gt 300 ]; then
        _cq_iv=5
    fi
    CQ_INTERVAL_SEC="$_cq_iv"
    CQ_STALE_THRESHOLD=$((3 * _cq_iv))
    [ "$CQ_STALE_THRESHOLD" -lt 15 ] && CQ_STALE_THRESHOLD=15

    _cq_age=""
    case "$_cq_mono" in
        ''|*[!0-9]*|0) ;;
        *)
            _cq_up=""
            { read -r _cq_up _cq_idle < /proc/uptime; } 2>/dev/null
            _cq_up="${_cq_up%%.*}"
            case "$_cq_up" in
                ''|*[!0-9]*) ;;
                *)
                    CQ_MONO="$_cq_mono"
                    _cq_age=$((_cq_up - _cq_mono))
                    if [ "$_cq_age" -lt 0 ]; then
                        CQ_AGE_SEC="$_cq_age"
                        CQ_STALE_REASON="mono ahead of uptime"
                        return 1
                    fi
                    ;;
            esac
            ;;
    esac
    [ -z "$_cq_age" ] && _cq_age=$(( $(date +%s) - _cq_ts ))
    CQ_AGE_SEC="$_cq_age"
    if [ "$_cq_age" -gt "$CQ_STALE_THRESHOLD" ]; then
        CQ_STALE_REASON="age ${_cq_age}s > ${CQ_STALE_THRESHOLD}s"
        return 1
    fi

    CQ_STALE=0
    CQ_TIMESTAMP="$_cq_ts"
    case "$_cq_reach" in true|false) CQ_REACHABLE="$_cq_reach" ;; esac
    case "$_cq_rtt" in ''|-|*[!0-9.]*) ;; *) CQ_RTT_MS="$_cq_rtt" ;; esac
    case "$_cq_ss" in ''|*[!0-9]*) ;; *) CQ_STREAK_SUCCESS="$_cq_ss" ;; esac
    case "$_cq_sf" in ''|*[!0-9]*) ;; *) CQ_STREAK_FAIL="$_cq_sf" ;; esac
    [ "$_cq_dr" = "true" ] && CQ_DURING_RECOVERY="true"
    case "$_cq_fs" in ''|*[!0-9]*) ;; *) CQ_FAIL_SECS="$_cq_fs" ;; esac
    case "$_cq_rs" in ''|*[!0-9]*) ;; *) CQ_RECOVER_SECS="$_cq_rs" ;; esac
    [ "$_cq_prof" != "-" ] && CQ_PROFILE="$_cq_prof"
    [ "$_cq_fam" != "-" ] && CQ_LAST_FAMILY="$_cq_fam"
    [ "$_cq_tgt" != "-" ] && CQ_TARGET="$_cq_tgt"
    return 0
}

conn_state_why() {
    printf '%s' "${CQ_STALE_REASON:-unknown}"
}

conn_state_is_up() {
    [ "$CQ_STALE" = "0" ] && [ "$CQ_REACHABLE" = "true" ]
}

# conn_state_resolve <profile> [interval_override]
# The ONE profile table (seconds): sensitive 1/6/3, regular 2/10/6,
# relaxed 5/15/10, quiet 10/30/20 (interval / fail_secs / recover_secs).
# Unknown or empty profile -> relaxed. A valid override (integer 1-60) changes
# the probe interval ONLY: the thresholds are derived from the PROFILE's own
# interval, ceil(secs / profile_interval), so time-to-fail / time-to-recover
# stay stable per profile and the override does not re-derive them.
# Sets: CQ_CFG_PROFILE, CQ_CFG_PROFILE_INTERVAL_SEC, CQ_CFG_INTERVAL_OVERRIDE
#       ("" when unused), CQ_CFG_INTERVAL_SEC (effective), CQ_CFG_FAIL_SECS,
#       CQ_CFG_RECOVER_SECS, CQ_CFG_FAIL_THRESHOLD, CQ_CFG_RECOVER_THRESHOLD.
conn_state_resolve() {
    CQ_CFG_PROFILE="$1"
    case "$CQ_CFG_PROFILE" in
        sensitive) _cq_pi=1;  CQ_CFG_FAIL_SECS=6;  CQ_CFG_RECOVER_SECS=3  ;;
        regular)   _cq_pi=2;  CQ_CFG_FAIL_SECS=10; CQ_CFG_RECOVER_SECS=6  ;;
        quiet)     _cq_pi=10; CQ_CFG_FAIL_SECS=30; CQ_CFG_RECOVER_SECS=20 ;;
        *)
            CQ_CFG_PROFILE="relaxed"
            _cq_pi=5;  CQ_CFG_FAIL_SECS=15; CQ_CFG_RECOVER_SECS=10
            ;;
    esac
    CQ_CFG_PROFILE_INTERVAL_SEC="$_cq_pi"
    CQ_CFG_FAIL_THRESHOLD=$(( (CQ_CFG_FAIL_SECS + _cq_pi - 1) / _cq_pi ))
    CQ_CFG_RECOVER_THRESHOLD=$(( (CQ_CFG_RECOVER_SECS + _cq_pi - 1) / _cq_pi ))

    CQ_CFG_INTERVAL_OVERRIDE=""
    case "${2:-}" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$2" -ge 1 ] && [ "$2" -le 60 ]; then
                CQ_CFG_INTERVAL_OVERRIDE="$2"
            fi
            ;;
    esac
    CQ_CFG_INTERVAL_SEC="${CQ_CFG_INTERVAL_OVERRIDE:-$_cq_pi}"
    return 0
}

# conn_state_cadence: the cadence qmanager_ping runs from UCI
# (quecmanager.ping_profile.{profile,interval_override}). Correct even while
# the daemon is down, so CGIs use this rather than the cache.
conn_state_cadence() {
    _cq_cfg_prof=$(uci -q get quecmanager.ping_profile.profile 2>/dev/null)
    _cq_cfg_ovr=$(uci -q get quecmanager.ping_profile.interval_override 2>/dev/null)
    conn_state_resolve "$_cq_cfg_prof" "$_cq_cfg_ovr"
}

# ---------------------------------------------------------------------------
# The single alert wait (minutes), owned by Connection Quality
# ---------------------------------------------------------------------------
# An outage sends nothing on any channel unless it lasted this long.
CQ_SMS_CONFIG="${CQ_SMS_CONFIG:-/etc/qmanager/sms_alerts.json}"
CQ_EMAIL_CONFIG="${CQ_EMAIL_CONFIG:-/etc/qmanager/email_alerts.json}"
CQ_ALERT_AFTER_MIN=5

# _cq_wait_ok <value>: integer 1-1440.
_cq_wait_ok() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 1440 ] 2>/dev/null
}

# _cq_wait_from_json <file>: adopts the file's threshold_minutes when it is a valid number.
_cq_wait_from_json() {
    [ -f "$1" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    _cq_w=$(jq -r '(try .threshold_minutes catch null) | if type == "number" then tostring else "" end' \
        "$1" 2>/dev/null </dev/null)
    _cq_wait_ok "$_cq_w" || return 1
    CQ_ALERT_AFTER_MIN="$_cq_w"
}

# cq_alert_after_min: resolves CQ_ALERT_AFTER_MIN. Order: UCI
# quecmanager.quality_thresholds.alert_after_min, else the SMS then email
# threshold_minutes (where the wait lived before it moved here), else 5.
cq_alert_after_min() {
    CQ_ALERT_AFTER_MIN=5
    _cq_w=$(uci -q get quecmanager.quality_thresholds.alert_after_min 2>/dev/null)
    if _cq_wait_ok "$_cq_w"; then
        CQ_ALERT_AFTER_MIN="$_cq_w"
        return 0
    fi
    _cq_wait_from_json "$CQ_SMS_CONFIG" && return 0
    _cq_wait_from_json "$CQ_EMAIL_CONFIG" && return 0
    return 0
}
