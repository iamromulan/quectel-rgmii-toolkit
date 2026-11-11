#!/bin/sh
# =============================================================================
# wd_detect.sh - qmanager_watchcat: inputs that start or hold recovery
# =============================================================================
# Sourced by qmanager_watchcat (never executed). BusyBox ash safe.
#
# Owns: ping_streak_fail, ping_reachable, ping_during_recovery, q_avg_latency,
#       q_packet_loss, quality_breach_counter, ssr_hold, last_ssr_detected,
#       ssr_hold_started, quality_since
# Functions: read_ping, read_quality, wd_quality_mark, quality_breached,
#            wd_decide_start, wd_holdoff_left, wd_radio_reconcile,
#            wd_start_gate, evaluate_quality,
#            ssr_in_progress, ssr_hold_gate, ssr_hold_clear
#
# evaluate_quality starts the recovery ladder (find_next_tier / do_recovery from
# wd_tiers.sh), so it writes state, recovery_reason and current_tier, which other
# libs own. Function definitions and global initialisers only. The last line sets
# WD_DETECT_LOADED.
# =============================================================================

# --- State Variables (owned here) --------------------------------------------
quality_breach_counter=0
ssr_hold="false"          # JSON bool literal for write_state
last_ssr_detected="null"  # JSON null literal or monotonic-seconds integer
ssr_hold_started=0        # monotonic seconds-since-boot when hold began; 0 = not holding

# Read ping daemon data — returns 0 if valid, 1 if stale/missing
# Sets: ping_streak_fail, ping_reachable, ping_during_recovery
ping_streak_fail=0
ping_reachable="true"
ping_during_recovery="false"

read_ping() {
    # conn_state_read owns the read + staleness rule (max(3 * interval_sec, 15)
    # on the monotonic clock). On failure the ping_* vars keep their previous
    # values; every caller treats a non-zero return as "unknown, skip".
    if ! conn_state_read; then
        if [ "$CQ_STALE_REASON" = "missing" ]; then
            qlog_warn "Ping cache missing"
        else
            qlog_warn "Ping data stale ($(conn_state_why)), skipping cycle"
        fi
        return 1
    fi

    # reachable is true/false, or "null" when the cache did not say — "null"
    # is never treated as up. The down decision stays on the probe-count streak.
    ping_streak_fail="$CQ_STREAK_FAIL"
    ping_reachable="$CQ_REACHABLE"
    ping_during_recovery="$CQ_DURING_RECOVERY"
    return 0
}

# Quality window. Quality is judged from the ping daemon's raw sample history
# (one RTT in ms or the word "null" per line, newest last), not from the poller's
# status.json, so a long-gone outage cannot leak into a fresh decision.
# quality_since is the monotonic second the window starts at: wd_quality_mark
# resets it after every event that makes older samples meaningless (startup, an
# outage, a recovery action, a SIM swap, a LOCKED or radio-off exit). The window
# holds at most W samples, W = clamp(120 / ping interval, 6, 60), and at least 3
# samples must have accrued since the mark or there is no signal.
quality_since=0
WD_PING_HISTORY="/tmp/qmanager_ping_history"

wd_quality_mark() {
    quality_since=$(mono_now)
    case "$quality_since" in ''|*[!0-9]*) quality_since=0 ;; esac
}

# Returns 0 with the window's figures, 1 for no signal (too few samples since the
# mark, or no history). Freshness is the caller's job: read_ping has already run
# this pass and a stale ping cache stops the pass before this is reached.
# Sets: q_avg_latency (may be "null"), q_packet_loss (integer 0-100)
q_avg_latency="null"
q_packet_loss="0"
read_quality() {
    local iv
    local w
    local n
    local now
    local since
    local out

    iv="$CQ_INTERVAL_SEC"
    case "$iv" in ''|*[!0-9]*) iv=5 ;; esac
    [ "$iv" -ge 1 ] || iv=5
    w=$((120 / iv))
    [ "$w" -lt 6 ] && w=6
    [ "$w" -gt 60 ] && w=60

    now=$(mono_now)
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    since="$quality_since"
    case "$since" in ''|*[!0-9]*) since=0 ;; esac
    [ "$now" -ge "$since" ] || return 1
    n=$(( (now - since) / iv ))
    [ "$n" -gt "$w" ] && n=$w
    [ "$n" -ge 3 ] || return 1

    [ -f "$WD_PING_HISTORY" ] || return 1
    out=$(tail -n "$n" "$WD_PING_HISTORY" 2>/dev/null | awk '
        { c++ }
        $0 ~ /^[0-9]+(\.[0-9]+)?$/ { s += $0; k++; next }
        { nl++ }
        END {
            if (c < 3) exit 1
            if (k > 0) avg = sprintf("%.1f", s / k); else avg = "null"
            printf "%s %d\n", avg, int(nl * 100 / c)
        }')
    [ -n "$out" ] || return 1
    q_avg_latency="${out% *}"
    q_packet_loss="${out#* }"
    case "$q_packet_loss" in ''|*[!0-9]*) q_packet_loss=0 ;; esac
    return 0
}

# Decide whether current quality (already read by read_quality) breaches the
# configured ceilings. OR logic; a ceiling of 0 means IGNORE that metric.
# avg_latency_ms is a FLOAT — comparison MUST use awk (BusyBox [ -gt ] errors
# on decimals). Returns 0 if breached, 1 if not.
quality_breached() {
    # latency: only if threshold > 0 AND we have a numeric windowed average
    if [ "$CFG_LATENCY_THRESHOLD_MS" -gt 0 ] 2>/dev/null && [ "$q_avg_latency" != "null" ]; then
        if awk -v a="$q_avg_latency" -v c="$CFG_LATENCY_THRESHOLD_MS" 'BEGIN{ exit !((a+0) > (c+0)) }'; then
            qlog_warn "QUALITY breach: avg latency ${q_avg_latency}ms > ${CFG_LATENCY_THRESHOLD_MS}ms (shared)"
            return 0
        fi
    fi
    # loss: only if threshold > 0
    if [ "$CFG_LOSS_THRESHOLD_PCT" -gt 0 ] 2>/dev/null; then
        if [ "$q_packet_loss" -ge "$CFG_LOSS_THRESHOLD_PCT" ] 2>/dev/null; then
            qlog_warn "QUALITY breach: loss ${q_packet_loss}% >= ${CFG_LOSS_THRESHOLD_PCT}% (shared)"
            return 0
        fi
    fi
    return 1
}

# Pure start gate (no I/O, no globals), in this order:
#   wd_decide_start <tiers_any 0|1> <cfun> <holdoff_left_secs>
#   none       no tier is enabled: there is nothing to run, stay as we are
#   holdoff    the ladder ran out recently: wait out the pause
#   radio_off  AT+CFUN is 0 or 4: the radio was turned off on purpose
#   go         start the ladder
# cfun is the digit wd_cfun_now printed; empty (unreadable) counts as on, so a
# failed read never blocks recovery.
wd_decide_start() {
    local hl
    hl="$3"
    case "$hl" in ''|*[!0-9]*) hl=0 ;; esac
    if [ "$1" != "1" ]; then
        printf 'none'
        return 0
    fi
    if [ "$hl" -gt 0 ]; then
        printf 'holdoff'
        return 0
    fi
    case "$2" in
        0|4) printf 'radio_off' ;;
        *) printf 'go' ;;
    esac
    return 0
}

# Prints the seconds left of the pause after an exhausted ladder (0 = none).
wd_holdoff_left() {
    local now
    case "$holdoff_until" in
        ''|*[!0-9]*) printf '0'; return 0 ;;
    esac
    now=$(mono_now)
    case "$now" in ''|*[!0-9]*) now=0 ;; esac
    if [ "$holdoff_until" -gt "$now" ]; then
        printf '%s' $((holdoff_until - now))
    else
        printf '0'
    fi
    return 0
}

# A Tier 2 or SIM-swap radio marker (wd_radio_down=1) is cleared only by a
# confirmed AT+CFUN=1. If every confirming read failed, the marker sticks: the
# start gate then ignores a later airplane mode and the exit cleanup would send
# AT+CFUN=1 over the user's CFUN=0/4. Call this right before wd_start_gate (never
# inside its command substitution: a subshell cannot clear the marker). It reads
# AT+CFUN? only while the marker is set and clears it when the radio reads 1; a
# 0, a 4 or an unreadable reply keeps the marker (ours or the user's, undecidable).
# Nothing is read while the gate is paused by the hold-off: it decides without CFUN.
wd_radio_reconcile() {
    [ "$wd_radio_down" = "1" ] || return 0
    [ "$(wd_holdoff_left)" = "0" ] || return 0
    if [ "$(wd_cfun_now)" = "1" ]; then
        qlog_info "Radio reads AT+CFUN=1: clearing the stale radio-down marker"
        wd_mark_radio_up
    fi
    return 0
}

# Gathers the three inputs for wd_decide_start and prints its verdict. The one
# AT read (AT+CFUN?) is skipped when an earlier gate already decides. While a
# Tier 2 radio toggle is unresolved (wd_radio_down=1) a radio that is off is ours,
# not the user's, so it is reported as on and the ladder keeps escalating.
wd_start_gate() {
    local any
    local hl
    local cf
    any=0
    [ "$CFG_TIER1_ENABLED" = "1" ] && any=1
    [ "$CFG_TIER2_ENABLED" = "1" ] && any=1
    [ "$CFG_TIER3_ENABLED" = "1" ] && any=1
    [ "$CFG_TIER4_ENABLED" = "1" ] && any=1

    hl=$(wd_holdoff_left)

    cf=""
    if [ "$any" = "1" ] && [ "$hl" -eq 0 ] && [ "$wd_radio_down" != "1" ]; then
        cf=$(wd_cfun_now)
    fi
    wd_decide_start "$any" "$cf" "$hl"
}

# Accrue the consecutive-breach counter and, on reaching the threshold, kick
# off the SAME Tier 1->4 recovery ladder used by the reachability path.
# Returns 0 if it TRIGGERED recovery this cycle (caller skips rest of cycle),
# 1 otherwise.
evaluate_quality() {
    [ "$CFG_QUALITY_ENABLED" = "1" ] || return 1
    if ! read_quality; then
        # no-signal: leave counter unchanged (never count as breach, never reset)
        return 1
    fi
    if quality_breached; then
        quality_breach_counter=$((quality_breach_counter + 1))
        qlog_info "QUALITY: breach ${quality_breach_counter}/${CFG_QUALITY_CONSECUTIVE} (avg ${q_avg_latency}ms vs ${CFG_LATENCY_THRESHOLD_MS}ms, loss ${q_packet_loss}% vs ${CFG_LOSS_THRESHOLD_PCT}%)"
        if [ "$quality_breach_counter" -ge "$CFG_QUALITY_CONSECUTIVE" ]; then
            local gate
            wd_radio_reconcile
            gate=$(wd_start_gate)
            case "$gate" in
                none|holdoff)
                    # Nothing to run, or paused after an exhausted ladder: no
                    # recovery, no event; the breach count restarts.
                    qlog_debug "QUALITY: recovery not started ($gate)"
                    quality_breach_counter=0
                    return 1
                    ;;
                radio_off)
                    wd_enter_radio_off
                    return 0
                    ;;
            esac
            qlog_warn "QUALITY → RECOVERY: ${CFG_QUALITY_CONSECUTIVE} consecutive breaches (avg ${q_avg_latency}ms / loss ${q_packet_loss}% vs ${CFG_LATENCY_THRESHOLD_MS}ms / ${CFG_LOSS_THRESHOLD_PCT}%)"
            append_event "watchcat_recovery" "Watchcat: connection quality degraded (latency ${q_avg_latency}ms / loss ${q_packet_loss}%) — starting recovery" "warning"
            quality_breach_counter=0
            recovery_reason="quality"

            # SSR-aware hold: if a recoverable baseband SSR is mid-flight, hold
            # the ladder this cycle rather than forcing a detach. Not the main
            # loop here — return from evaluate_quality so do_recovery is skipped;
            # the main loop's write_state + sleep proceed normally.
            if ssr_hold_gate; then
                state="ssr_hold"
                return 0
            fi

            state="recovery"
            if [ "$current_tier" -eq 0 ]; then
                find_next_tier 1
            fi
            do_recovery
            return 0
        fi
    else
        quality_breach_counter=0
    fi
    return 1
}

# --- SSR (baseband subsystem restart) awareness ---------------------------
# The RM551E periodically suffers RECOVERABLE Qualcomm MPSS baseband SSRs: the
# kernel logs "4080000.remoteproc-mss: fatal error received" then brings the
# remoteproc back up ~3-4s later, with the data path restored in ~10-25s. If
# watchcat fires its recovery ladder (forced AT+COPS / AT+CFUN detach) WHILE the
# baseband is mid-self-heal, it amplifies a ~30-60s self-healing outage into a
# multi-minute thrash. This gate detects an in-progress SSR and HOLDS the ladder
# for a grace window, only falling through to the normal ladder if connectivity
# does not return (the genuine stuck / AP-hang case).

# Best-effort read-only check of the kernel ring buffer for a RECENT MPSS crash.
# Returns 0 (true) if a fatal-error line exists AND it is within the detection
# window of now (CFG_SSR_GRACE + CFG_FAIL_THRESHOLD * ping interval + 2 check
# intervals); 1 (false) otherwise — including when dmesg yields nothing, the
# crash line was evicted, or the timestamp fails to parse (graceful degradation:
# absence of evidence is NOT evidence of absence; we never block recovery on it).
# dmesg timestamps are monotonic seconds-since-boot floats like "[ 12345.678901]"
# (BusyBox dmesg has no -T / -l); we parse integer seconds only and compare to
# /proc/uptime. Calls dmesg ONCE per invocation (only at an escalation decision).
ssr_in_progress() {
    [ "$CFG_SSR_AWARE" = "1" ] || return 1

    local crash_line
    local crash_ts
    local now

    crash_line=$(dmesg 2>/dev/null | grep "4080000.remoteproc-mss: fatal error received" | tail -n 1)
    [ -n "$crash_line" ] || return 1

    # Extract leading integer seconds from the dmesg monotonic timestamp. Real
    # lines on this kernel are double-bracketed: "[ 12345.678901][ T8033] msg"
    # (CONFIG_PRINTK_CALLER); the older single-bracket "[ 12345.678901] msg" also
    # works. sed (not awk -F) because BusyBox awk 1.36.1 rejects a bracket-class
    # field separator as an "Unknown collating element" — verified on-device.
    crash_ts=$(printf '%s' "$crash_line" | sed 's/^\[[ ]*\([0-9]*\)\..*/\1/')
    case "$crash_ts" in ''|*[!0-9]*) return 1 ;; esac

    now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    case "$now" in ''|*[!0-9]*) return 1 ;; esac

    # The crash is only visible to the ladder once the ping daemon has counted
    # CFG_FAIL_THRESHOLD failed probes (CQ_INTERVAL_SEC apart) and a check pass
    # has seen them, so the look-back must cover that detection delay as well as
    # the grace. A bare grace window always expired first on slow ping profiles
    # (the hold never engaged and every SSR was amplified).
    local iv
    local ft
    local ci
    local gr
    local win
    gr="$CFG_SSR_GRACE"
    case "$gr" in ''|*[!0-9]*) gr=45 ;; esac
    iv="$CQ_INTERVAL_SEC"
    case "$iv" in ''|*[!0-9]*) iv=5 ;; esac
    ft="$CFG_FAIL_THRESHOLD"
    case "$ft" in ''|*[!0-9]*) ft=5 ;; esac
    ci="$CFG_CHECK_INTERVAL"
    case "$ci" in ''|*[!0-9]*) ci=10 ;; esac
    win=$((gr + ft * iv + 2 * ci))

    local delta
    delta=$((now - crash_ts))
    [ "$delta" -ge 0 ] && [ "$delta" -le "$win" ] && return 0
    return 1
}

# Decide whether to HOLD the recovery ladder this cycle. Returns 0 to HOLD
# (caller skips do_recovery and lets the modem self-heal), 1 to PROCEED to the
# normal ladder. Sits BELOW all existing guards (LOCKED, cooldown, revert) and
# only intercepts at the do_recovery initiation sites.
ssr_hold_gate() {
    local now
    local held

    # Already holding? Check whether the grace window expired.
    if [ "$ssr_hold" = "true" ]; then
        now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
        case "$now" in ''|*[!0-9]*) now=0 ;; esac
        held=$((now - ssr_hold_started))
        if [ "$held" -ge "$CFG_SSR_GRACE" ]; then
            qlog_warn "SSR-hold grace (${CFG_SSR_GRACE}s) expired without recovery; releasing to ladder"
            ssr_hold="false"
            ssr_hold_started=0
            return 1   # fall through to the normal ladder (genuine stuck case)
        fi
        return 0       # keep holding
    fi

    # Not yet holding — start a hold only if an SSR is detectable right now.
    if ssr_in_progress; then
        now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
        case "$now" in ''|*[!0-9]*) now=0 ;; esac
        ssr_hold="true"
        ssr_hold_started="$now"
        last_ssr_detected="$now"   # monotonic seconds; UI surfaces "self-recovery"
        qlog_warn "Recoverable baseband SSR detected; holding recovery ladder up to ${CFG_SSR_GRACE}s for self-heal"
        append_event "watchcat_recovery" "Watchcat: recoverable baseband restart detected — holding recovery to let the modem self-heal" "info"
        return 0
    fi
    return 1
}

# Clear an SSR hold on natural recovery (connectivity returned on its own — the
# expected happy path; we did nothing harmful). Idempotent.
ssr_hold_clear() {
    if [ "$ssr_hold" = "true" ]; then
        qlog_info "SSR-hold cleared: connectivity recovered naturally"
    fi
    ssr_hold="false"
    ssr_hold_started=0
}

WD_DETECT_LOADED=1
