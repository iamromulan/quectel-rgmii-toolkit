#!/bin/sh
# =============================================================================
# wd_ledger.sh - qmanager_watchcat: reboot ledger (crash.log) accounting
# =============================================================================
# Sourced by qmanager_watchcat (never executed). BusyBox ash safe.
#
# Owns: reboots_this_hour, _rb_next
# Functions: count_recent_reboots, wd_ledger_tick, wd_ledger_recent_json
#
# Reads CRASH_LOG (defined by the daemon). Function definitions and global
# initialisers only, so a CGI may source it for wd_ledger_recent_json. The last
# line sets WD_LEDGER_LOADED.
# =============================================================================

# --- State Variables (owned here) --------------------------------------------
reboots_this_hour=0
_rb_next=0                # mono_now at/after which wd_ledger_tick recounts

# 0 iff the wall clock is plausible. Prefers schedule_guard.sh's _qm_clock_sane
# (sourced by the daemon); the fallback applies the same rule (year >= 2025).
_wd_clock_sane() {
    if command -v _qm_clock_sane >/dev/null 2>&1; then
        _qm_clock_sane
        return
    fi
    local y
    y=$(date +%Y)
    case "$y" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$y" -ge 2025 ]
}

# Count WATCHDOG reboots in the last hour from crash.log.
# crash.log is now a shared reboot ledger: watchcat writes tier4_escalation rows,
# and record_planned_reboot (qlog.sh) writes user/unplanned rows for the reboot-
# alert feature. The tier-4 token bucket + the dashboard's reboots_this_hour must
# keep their original meaning ("watchdog-caused reboots this hour"), so we count
# ONLY tier4_escalation rows here. Field layout: <epoch>|reboot|<reason>.
#
# The window is a rolling hour on the wall clock. The RM551E boots at 1970 until
# NITZ/ntp steps the clock, so with an insane clock the window cannot be
# evaluated: count every row older than 2025-01-01 (the clock-less boot rows).
# That over-counts, which is the safe direction for the Tier-4 cap; the first
# recount on a sane clock drops them again.
count_recent_reboots() {
    if [ ! -f "$CRASH_LOG" ]; then
        reboots_this_hour=0
        return
    fi
    local now
    local sane
    local count
    now=$(date +%s)
    case "$now" in
        ''|*[!0-9]*) now=0 ;;
    esac
    if _wd_clock_sane; then
        sane=1
    else
        sane=0
    fi
    count=$(awk -v now="$now" -v sane="$sane" -F'|' '
        $2 == "reboot" && $3 == "tier4_escalation" && $1 ~ /^[0-9]+$/ {
            if (sane == 1) { if ($1 + 0 >= now - 3600) n++ }
            else if ($1 + 0 < 1735689600) n++
        }
        END { print n + 0 }' "$CRASH_LOG" 2>/dev/null)
    case "$count" in
        ''|*[!0-9]*) count=0 ;;
    esac
    reboots_this_hour="$count"
}

# Recount at most once a minute so the figure decays when a row ages out of the
# hour. Called as the first statement of every main-loop pass (before the reload
# check), so it also runs while locked, in cooldown or on any early `continue`.
wd_ledger_tick() {
    local now
    now=$(mono_now)
    case "$now" in
        ''|*[!0-9]*) return 0 ;;
    esac
    if [ "$now" -ge "$_rb_next" ]; then
        count_recent_reboots
        _rb_next=$((now + 60))
    fi
}

# Watchdog (Tier-4) reboots for the Watchdog page's Recent Activity: a JSON
# array of epoch ints, newest first, at most <limit> (default 5), "[]" on any
# problem. Uses no daemon globals (CRASH_LOG falls back to the device path) and
# is safe to source from a CGI. Same awk approach as monitoring/alerts.sh; the
# device jq has no regex, so numeric epochs are matched in awk.
wd_ledger_recent_json() {
    local limit
    local file
    local rows
    local out
    limit="$1"
    case "$limit" in
        ''|*[!0-9]*) limit=5 ;;
    esac
    file="${CRASH_LOG:-/etc/qmanager/crash.log}"
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        printf '[]'
        return 0
    fi
    rows=$(awk -F'|' '
        $2 == "reboot" && $3 == "tier4_escalation" && $1 ~ /^[0-9]+$/ {
            printf "%s%s", sep, $1 + 0
            sep = ","
        }' "$file" 2>/dev/null)
    if [ -z "$rows" ]; then
        printf '[]'
        return 0
    fi
    out=$(printf '[%s]' "$rows" | jq -c --argjson n "$limit" 'sort | reverse | .[0:$n]' 2>/dev/null)
    if [ -z "$out" ]; then
        printf '[]'
        return 0
    fi
    printf '%s' "$out"
}

WD_LEDGER_LOADED=1
