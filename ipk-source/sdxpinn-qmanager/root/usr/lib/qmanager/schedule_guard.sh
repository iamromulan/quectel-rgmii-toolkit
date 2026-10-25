#!/bin/sh
# =============================================================================
# schedule_guard.sh — clock-step fire guard for cron-fired workers (issue #9)
# =============================================================================
# The RM551E's PMIC RTC does not keep real time: the kernel boots at 1970,
# sysfixtime sets the clock to the newest /etc mtime (often minutes or days
# stale), and time_daemon / sysntpd step it forward later. BusyBox crond runs
# every job whose minute it crosses on a forward step of up to 60 minutes, so a
# boot that lands just before a scheduled minute and steps past it fires that
# job: a 04:00 scheduled reboot can then re-fire after every reboot.
#
# Uptime is the one input a clock step cannot move, so it is a required leg:
#   allowed iff clock_sane AND boot_settled AND day_mask AND (no sched OR now
#   within QM_SCHED_TOLERANCE_MIN of sched)
# A deny is a logged clean skip (exit 0 in the caller), never a failure.
# crond fires on the exact minute, so the tolerance is 2 min (the RM520N source
# uses 10 for systemd timer accuracy).
#
# HH:MM is converted with awk, never $(( )): zero-padded fields are octal in ash
# and $((08)) is a parse error.
#
# Test hooks: QM_TIMER_GUARD_BYPASS, QM_TEST_YEAR, QM_TEST_UPTIME,
# QM_TEST_NOW_HHMM, QM_TEST_DOW.
# Install location: /usr/lib/qmanager/schedule_guard.sh
# =============================================================================

QM_TIMER_SETTLE_SECS="${QM_TIMER_SETTLE_SECS:-300}"
QM_SCHED_TOLERANCE_MIN="${QM_SCHED_TOLERANCE_MIN:-2}"

# _qm_validate_hhmm <HH:MM>
_qm_validate_hhmm() {
    case "$1" in
        [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) return 0 ;;
    esac
    return 1
}

# _qm_clock_sane
# 0 iff the wall-clock year is numeric and >= 2025; fails closed otherwise.
_qm_clock_sane() {
    local y
    if [ -n "$QM_TEST_YEAR" ]; then
        y="$QM_TEST_YEAR"
    else
        y=$(date +%Y)
    fi
    _qm_seen_year="$y"
    case "$y" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$y" -ge 2025 ]
}

# _qm_boot_settled
# 0 iff uptime >= QM_TIMER_SETTLE_SECS; fails closed on an unreadable uptime.
_qm_boot_settled() {
    local up
    if [ -n "$QM_TEST_UPTIME" ]; then
        up="$QM_TEST_UPTIME"
    else
        up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    fi
    _qm_seen_uptime="$up"
    case "$up" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$up" -ge "$QM_TIMER_SETTLE_SECS" ]
}

# _qm_today_in_days <days_csv> (0=Sun..6=Sat)
# Fails closed on a non-numeric "today".
_qm_today_in_days() {
    local days="$1"
    local today
    local d
    if [ -n "$QM_TEST_DOW" ]; then
        today="$QM_TEST_DOW"
    else
        today=$(date +%w)
    fi
    _qm_seen_dow="$today"
    case "$today" in
        ''|*[!0-9]*) return 1 ;;
    esac
    for d in $(printf '%s' "$days" | tr ',' ' '); do
        [ "$d" = "$today" ] && return 0
    done
    return 1
}

# _qm_now_matches_hhmm <HH:MM> [tolerance-min]
# 0 iff now is within tolerance of HH:MM, wrapping midnight. Fails closed on any
# unparsable operand (empty awk output must never read as 0).
_qm_now_matches_hhmm() {
    local sched="$1"
    local tol="${2:-$QM_SCHED_TOLERANCE_MIN}"
    local now
    local sched_min
    local now_min
    local d
    _qm_validate_hhmm "$sched" || return 1
    if [ -n "$QM_TEST_NOW_HHMM" ]; then
        now="$QM_TEST_NOW_HHMM"
    else
        now=$(date +%H:%M)
    fi
    _qm_seen_now="$now"
    _qm_validate_hhmm "$now" || return 1
    case "$tol" in
        ''|*[!0-9]*) return 1 ;;
    esac
    sched_min=$(printf '%s' "$sched" | awk -F: '{print $1*60+$2}')
    now_min=$(printf '%s' "$now" | awk -F: '{print $1*60+$2}')
    case "$sched_min" in ''|*[!0-9]*) return 1 ;; esac
    case "$now_min" in ''|*[!0-9]*) return 1 ;; esac
    d=$((now_min - sched_min))
    [ "$d" -lt 0 ] && d=$((-d))
    [ "$d" -gt 720 ] && d=$((1440 - d))
    [ "$d" -le "$tol" ]
}

# _qm_timer_fire_allowed <HH:MM-or-empty> [days_csv]
# Returns 0 to allow the fire. An empty sched passes the minute leg on purpose
# (a scenario timeline has no single minute); a caller that HAS a schedule but
# cannot read it must deny itself before calling, with _qm_validate_hhmm.
# Sets QM_GUARD_REASON on deny for the caller's log line.
_qm_timer_fire_allowed() {
    local sched="$1"
    local days="$2"
    QM_GUARD_REASON=""
    [ "$QM_TIMER_GUARD_BYPASS" = "1" ] && return 0
    if ! _qm_clock_sane; then
        QM_GUARD_REASON="clock not set (year $_qm_seen_year)"
        return 1
    fi
    if ! _qm_boot_settled; then
        QM_GUARD_REASON="boot not settled (uptime ${_qm_seen_uptime}s < ${QM_TIMER_SETTLE_SECS}s)"
        return 1
    fi
    if [ -n "$days" ] && ! _qm_today_in_days "$days"; then
        QM_GUARD_REASON="today ($_qm_seen_dow) not in days $days"
        return 1
    fi
    [ -z "$sched" ] && return 0
    if ! _qm_now_matches_hhmm "$sched"; then
        QM_GUARD_REASON="now $_qm_seen_now is not the scheduled $sched"
        return 1
    fi
    return 0
}
