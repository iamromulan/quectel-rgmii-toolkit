#!/bin/sh
# =============================================================================
# wd_sim.sh - qmanager_watchcat: Tier 3 SIM failover, fallback, revert, recheck
# =============================================================================
# Sourced by qmanager_watchcat (never executed). BusyBox ash safe.
#
# Owns: sim_failover_active, original_sim_slot, original_sim_iccid,
#       current_sim_slot, revert_settle_active, primary_recheck_active,
#       recheck_return_slot, recheck_interrupted, last_recheck_time,
#       wd_sim_revert_pending
# Functions: wd_read_slot, wd_swap_slot, wd_failover_save, wd_failover_clear,
#            _wd_failover_json, _wd_failover_del, wd_sim_adopt_live_slot,
#            wd_sim_defer_revert, execute_tier3, sim_failover_fallback,
#            finalize_sim_failover, initiate_primary_recheck,
#            _wd_sim_revert_run, check_revert_request, wd_sim_on_radio_back,
#            wd_sim_finish_recheck, wd_sim_resume_at_start,
#            wd_sim_resume_retry, wd_sim_on_unlock
#
# The failover record lives in two places: /tmp (fast, what the poller reads)
# and /etc/qmanager (flash, survives a reboot). Only wd_failover_save and
# wd_failover_clear write or remove them.
#
# Every SIM slot change goes through wd_swap_slot, which proves the swap by
# reading the slot back: AT+QUIMSLOT= can return OK and change nothing.
#
# The wd_sim_* functions are verbatim blocks lifted out of finish_cooldown
# (wd_tiers.sh) and main() (qmanager_watchcat) so every SIM-failover path lives
# in this file; each is called from the spot it came from. They also write
# globals owned by other libs (state, cooldown_remaining, recovery_reason,
# current_tier, ...), as the originals did. Function definitions and global
# initialisers only. The last line sets WD_SIM_LOADED.
# =============================================================================

# --- State Variables (owned here) --------------------------------------------
sim_failover_active="false"
original_sim_slot="null"
original_sim_iccid=""           # ICCID of the original (pre-swap) SIM; "" = unknown
current_sim_slot="null"
revert_settle_active="false"    # "true" while holding the post-revert SIM settle floor
primary_recheck_active="false"  # "true" while holding the blind primary-recheck settle floor
recheck_return_slot="null"      # backup slot to return to if a primary recheck fails
recheck_interrupted="false"     # "true" when LOCKED abandoned a primary-recheck settle
last_recheck_time=0             # mono_now of the last failover finalize / recheck; auto-failback clock
                                # (monotonic: a boot-time clock step must not make a recheck due at once)

# Flags shared with the poller (qmanager_poller) and cellular/settings.sh.
WD_SIM_SWITCH_FLAG="/tmp/qmanager_sim_switch_active"       # poller pauses AT while present
WD_FORCE_TIER2_FLAG="/tmp/qmanager_force_tier2"
WD_REFRESH_POLICY_FLAG="/tmp/qmanager_refresh_policy_band"
WD_SWAP_NOOP="false"            # "true" when the last wd_swap_slot found the target already live
WD_SWAP_FLAG_OWNED=0            # 1 while this daemon holds $WD_SIM_SWITCH_FLAG (exit cleanup removes it)
wd_sim_revert_pending="false"   # "true": a Tier 3 swap-back was deferred because the user turned the radio off
WD_RESUME_RETRY_SECS=60         # spacing of wd_sim_resume_retry attempts
_wd_resume_next=0               # mono_now of the next resume retry; 0 = not armed yet
SIM_FAILOVER_DURABLE="/etc/qmanager/sim_failover.json"   # flash copy of $SIM_FAILOVER_FILE
WD_ADOPT_SLOT=""                # live slot digit the last wd_sim_adopt_live_slot read; "" = unreadable / not read

# Persist the failover record (one JSON line) to /tmp and to flash. Flash is
# written only here, at finalize and at a recheck return (rare). Refuses an
# empty record: a failed jq must never blank a good file.
wd_failover_save() {
    if [ -z "$1" ]; then
        qlog_error "SIM failover: refusing to save an empty record"
        return 1
    fi
    local _fs_rc
    _fs_rc=0
    printf '%s\n' "$1" | qm_atomic_write "$SIM_FAILOVER_FILE" || _fs_rc=1
    [ -d "${SIM_FAILOVER_DURABLE%/*}" ] || mkdir -p "${SIM_FAILOVER_DURABLE%/*}" 2>/dev/null
    printf '%s\n' "$1" | qm_durable_write "$SIM_FAILOVER_DURABLE" || _fs_rc=1
    [ "$_fs_rc" -eq 0 ] || qlog_warn "SIM failover: could not write the record to /tmp or flash"
    return "$_fs_rc"
}

# Remove the failover record from /tmp and from flash.
wd_failover_clear() {
    rm -f "$SIM_FAILOVER_FILE" "$SIM_FAILOVER_DURABLE"
}

# Prints the failover record for the current original_sim_slot / current_sim_slot:
#   _wd_failover_json <reason> <current ICCID or ""> [unconfirmed]
# "unconfirmed" adds confirmed:false: the swap happened but the cooldown has not
# judged the link yet (a restart resumes it like any failover and drops the flag).
# revert_pending:true is added while wd_sim_revert_pending is set, so a restart
# keeps a swap-back that was deferred for airplane mode.
_wd_failover_json() {
    local _fj_ts
    _fj_ts=$(date +%s)
    jq -n -c \
        --argjson orig "$original_sim_slot" \
        --argjson curr "$current_sim_slot" \
        --argjson ts "$_fj_ts" \
        --arg reason "$1" \
        --arg orig_iccid "$original_sim_iccid" \
        --arg iccid "$2" \
        --arg unconf "$3" \
        --arg pend "$wd_sim_revert_pending" \
        '{active:true, original_slot:$orig, current_slot:$curr, switched_at:$ts, reason:$reason, original_iccid:$orig_iccid, current_iccid:$iccid}
         | if $unconf == "unconfirmed" then . + {confirmed:false} else . end
         | if $pend == "true" then . + {revert_pending:true} else . end' 2>/dev/null
}

# Removes one key from the saved record (and rewrites both copies) only when the
# record has it, so a record without the key costs no flash write.
#   _wd_failover_del <key>
_wd_failover_del() {
    local _fd_json
    [ -f "$SIM_FAILOVER_FILE" ] || return 0
    _fd_json=$(jq -c --arg k "$1" 'if has($k) then del(.[$k]) else empty end' "$SIM_FAILOVER_FILE" 2>/dev/null)
    [ -n "$_fd_json" ] || return 0
    wd_failover_save "$_fd_json"
}

# Prints the live SIM's ICCID (up to 3 reads, 1 s apart), or nothing when it
# cannot be read. Callers treat empty as "unknown".
_wd_sim_iccid() {
    local _ic_try
    local _ic_raw
    local _ic_val
    _ic_val=""
    for _ic_try in 1 2 3; do
        _ic_raw=$(qcmd 'AT+QCCID' 2>/dev/null)
        _ic_val=$(printf '%s' "$_ic_raw" | grep '+QCCID:' | sed 's/+QCCID: //g' | tr -d '\r ')
        [ -n "$_ic_val" ] && break
        sleep 1
    done
    printf '%s' "$_ic_val"
}

# Prints the live SIM slot digit (up to 3 tries, 1 s apart), or nothing when it
# cannot be read. Callers treat empty as "unknown", never as a slot.
wd_read_slot() {
    local _rs_try
    local _rs_raw
    local _rs_slot
    for _rs_try in 1 2 3; do
        _rs_raw=$(qcmd 'AT+QUIMSLOT?' 2>/dev/null)
        _rs_slot=$(printf '%s' "$_rs_raw" | grep '+QUIMSLOT:' | sed 's/.*: *//' | tr -d '\r ')
        case "$_rs_slot" in
            ''|*[!0-9]*) ;;
            *) printf '%s' "$_rs_slot"; return 0 ;;
        esac
        [ "$_rs_try" -lt 3 ] && sleep 1
    done
    return 0
}

# Move the modem to SIM slot <target> and prove it. Two attempts of the
# CFUN=0 -> QUIMSLOT -> CFUN=1 sequence. Never AT+CFUN=1,1. The poller is held
# off AT by the SIM-switch flag for the duration. Return codes:
#   0  the slot reads back as <target> AND the radio is on (CFUN=1), or the
#      modem was already on <target> (WD_SWAP_NOOP=true)
#   1  the final re-read shows the modem is not on <target>: nothing to record
#   2  the modem IS on <target> but the radio is not confirmed on (the modem was
#      unresponsive or AT+CFUN? unreadable). A last AT+CFUN=1 was sent; if CFUN
#      still does not read 1 the radio-down marker stays set, so the exit cleanup
#      and wd_radio_reconcile restore it. Callers record <target> as the real
#      slot, exactly as for 0.
#   3  the final re-read of the slot failed too: the swap may or may not have
#      happened. A caller that must know calls wd_sim_adopt_live_slot (it reads the
#      slot again); one that only needs "not proven" treats this like 1.
wd_swap_slot() {
    local _sw_target
    local _sw_live
    local _sw_cfun
    local _sw_attempt
    local _sw_ok
    _sw_target="$1"
    WD_SWAP_NOOP="false"

    case "$_sw_target" in
        ''|*[!0-9]*)
            qlog_error "SIM swap: invalid target slot '$_sw_target'"
            return 1
            ;;
    esac

    _sw_live=$(wd_read_slot)
    if [ "$_sw_live" = "$_sw_target" ]; then
        WD_SWAP_NOOP="true"
        qlog_info "SIM swap: already on slot $_sw_target, radio not cycled"
        return 0
    fi

    _sw_ok=1
    _sw_attempt=1
    while [ "$_sw_attempt" -le 2 ]; do
        # Re-touched each attempt: the poller drops a flag older than its max age.
        : > "$WD_SIM_SWITCH_FLAG"
        WD_SWAP_FLAG_OWNED=1
        command -v write_state_busy >/dev/null 2>&1 && write_state_busy
        wd_mark_radio_down
        qcmd 'AT+CFUN=0' >/dev/null 2>&1
        sleep 2
        qcmd "AT+QUIMSLOT=$_sw_target" >/dev/null 2>&1
        sleep 2
        qcmd 'AT+CFUN=1' >/dev/null 2>&1

        if wait_for_modem; then
            : > "$WD_SIM_SWITCH_FLAG"
            command -v write_state_busy >/dev/null 2>&1 && write_state_busy
            _sw_live=$(wd_read_slot)
            _sw_cfun=$(wd_cfun_now)
            if [ "$_sw_cfun" != "1" ]; then
                qlog_warn "SIM swap: CFUN is '${_sw_cfun:-unreadable}' after AT+CFUN=1, sending it again"
                qcmd 'AT+CFUN=1' >/dev/null 2>&1
                sleep 2
                _sw_cfun=$(wd_cfun_now)
            fi
            [ "$_sw_cfun" = "1" ] && wd_mark_radio_up
            if [ "$_sw_live" = "$_sw_target" ] && [ "$_sw_cfun" = "1" ]; then
                _sw_ok=0
                break
            fi
            qlog_warn "SIM swap attempt $_sw_attempt/2 to slot $_sw_target not verified (slot '${_sw_live:-unreadable}', CFUN '${_sw_cfun:-unreadable}')"
        else
            qlog_error "SIM swap attempt $_sw_attempt/2 to slot $_sw_target: modem unresponsive after CFUN=1"
        fi
        _sw_attempt=$((_sw_attempt + 1))
    done

    # Not proven, but the swap itself may have happened (the verification reads
    # failed, not the swap): look once more before reporting it as failed.
    if [ "$_sw_ok" -ne 0 ]; then
        _sw_live=$(wd_read_slot)
        if [ "$_sw_live" = "$_sw_target" ]; then
            qlog_warn "SIM swap: modem is on slot $_sw_target but the radio is not confirmed on, sending AT+CFUN=1 once more"
            qcmd 'AT+CFUN=1' >/dev/null 2>&1
            sleep 2
            _sw_cfun=$(wd_cfun_now)
            [ "$_sw_cfun" = "1" ] && wd_mark_radio_up
            _sw_ok=2
        elif [ -z "$_sw_live" ]; then
            qlog_warn "SIM swap: slot unreadable after the swap to slot $_sw_target, outcome unknown"
            _sw_ok=3
        fi
    fi

    rm -f "$WD_SIM_SWITCH_FLAG"
    WD_SWAP_FLAG_OWNED=0
    if [ "$_sw_ok" -eq 1 ]; then
        return 1
    fi

    # Dashboard shows the new SIM at once (same flags as cellular/settings.sh).
    touch "$WD_FORCE_TIER2_FLAG" "$WD_REFRESH_POLICY_FLAG"
    command -v wd_quality_mark >/dev/null 2>&1 && wd_quality_mark
    return "$_sw_ok"
}

execute_tier3() {
    # Pre-check: backup SIM configured
    if [ -z "$CFG_BACKUP_SIM_SLOT" ]; then
        qlog_warn "TIER 3 SKIPPED: no backup SIM slot configured"
        return 1
    fi

    # Read current SIM slot
    local current_slot
    current_slot=$(wd_read_slot)

    if [ -z "$current_slot" ]; then
        qlog_error "TIER 3: Cannot read current SIM slot"
        return 1
    fi

    if [ "$CFG_BACKUP_SIM_SLOT" = "$current_slot" ]; then
        qlog_warn "TIER 3 SKIPPED: backup slot ($CFG_BACKUP_SIM_SLOT) equals current slot ($current_slot)"
        return 1
    fi

    qlog_info "TIER 3: SIM failover from slot $current_slot to slot $CFG_BACKUP_SIM_SLOT"
    append_event "sim_failover" "Watchcat: switching to SIM slot $CFG_BACKUP_SIM_SLOT (Tier 3)" "warning"

    touch "$RECOVERY_FLAG"

    # Capture the ORIGINAL slot's ICCID (3×1s retry) BEFORE detaching, so the
    # failover file records an honest original_iccid. Best-effort: if it can't be
    # read after 3 tries, leave it "" and continue — never block the swap.
    # Kept local until the swap is verified: original_sim_slot/_iccid stay unset
    # for a swap that never happened.
    local _orig_iccid
    _orig_iccid=$(_wd_sim_iccid)

    # Stop tower failover daemon (locks are meaningless on different SIM)
    /etc/init.d/qmanager_tower_failover stop 2>/dev/null

    # Verified Golden Rule swap (wd_swap_slot). If the slot never moved there is
    # no failover to record: put tower failover back and skip the tier. Return 2
    # (on the backup slot, radio unconfirmed) is a swap that happened: it is
    # recorded below like a verified one and the cooldown judges the link.
    local _t3_swap_rc
    wd_swap_slot "$CFG_BACKUP_SIM_SLOT"
    _t3_swap_rc=$?
    if [ "$_t3_swap_rc" -eq 1 ]; then
        qlog_error "TIER 3: SIM swap to slot $CFG_BACKUP_SIM_SLOT not verified, skipping tier"
        append_event "sim_failover" "Watchcat: SIM swap to slot $CFG_BACKUP_SIM_SLOT did not take effect — skipped" "error"
        /etc/init.d/qmanager_tower_failover start 2>/dev/null
        return 1
    fi
    [ "$_t3_swap_rc" -eq 2 ] && qlog_warn "TIER 3: modem is on slot $CFG_BACKUP_SIM_SLOT, radio not confirmed on"

    original_sim_slot="$current_slot"
    original_sim_iccid="$_orig_iccid"
    current_sim_slot="$CFG_BACKUP_SIM_SLOT"

    # The swap is not proven to have happened or not (the slot read failed): ask
    # the modem again. Still on the original = no swap, skip the tier. On another
    # slot = adopt it (wd_sim_adopt_live_slot saved the record). Still unreadable =
    # assume it swapped and record it below; tower failover stays stopped until the
    # CPIN check or the fallback settles it.
    local _t3_save
    _t3_save=1
    if [ "$_t3_swap_rc" -eq 3 ]; then
        wd_sim_adopt_live_slot
        case "$WD_ADOPT_SLOT" in
            '')
                qlog_warn "TIER 3: slot still unreadable after the swap, assuming the modem is on slot $CFG_BACKUP_SIM_SLOT"
                ;;
            "$current_slot")
                qlog_error "TIER 3: modem is still on slot $current_slot, skipping tier"
                append_event "sim_failover" "Watchcat: SIM swap to slot $CFG_BACKUP_SIM_SLOT did not take effect — skipped" "error"
                original_sim_slot="null"
                original_sim_iccid=""
                current_sim_slot="null"
                /etc/init.d/qmanager_tower_failover start 2>/dev/null
                return 1
                ;;
            *)
                _t3_save=0
                ;;
        esac
    fi
    if [ "$_t3_save" -eq 1 ]; then
        local _t3_reason
        if [ "$recovery_reason" = "quality" ]; then
            _t3_reason="quality_degradation"
        else
            _t3_reason="connectivity_failure"
        fi
        wd_failover_save "$(_wd_failover_json "$_t3_reason" "" unconfirmed)"
    fi

    # Verify SIM presence. AT+CPIN? right after AT+CFUN=1 can answer
    # "+CME ERROR: 14" (SIM busy) while SIM init is still running, because
    # wait_for_modem only waits for a bare AT. One failed read is routine, not
    # proof the slot is empty, so retry 3x (1s apart) like the ICCID read above.
    # qcmd prints a modem ERROR on stdout with rc=0; a transport failure (lock
    # timeout, broker down) is rc!=0 with empty stdout. Only READY passes.
    local cpin_result
    local cpin_rc
    local cpin_try
    local cpin_ready
    cpin_result=""
    cpin_rc=1
    cpin_ready=0
    for cpin_try in 1 2 3; do
        cpin_result=$(qcmd 'AT+CPIN?' 2>/dev/null)
        cpin_rc=$?
        if [ "$cpin_rc" -eq 0 ] && printf '%s' "$cpin_result" | grep -q '^+CPIN: READY'; then
            cpin_ready=1
            break
        fi
        sleep 1
    done

    [ "$cpin_rc" -eq 0 ] || cpin_result=""
    # First non-empty reply line for the log ("no reply" on a transport failure).
    local cpin_reply
    cpin_reply=$(printf '%s\n' "$cpin_result" | tr -d '\r' | grep -v '^[[:space:]]*$' | head -1)
    [ -n "$cpin_reply" ] || cpin_reply="no reply"
    case "$cpin_ready:$cpin_result" in
        1:*) ;;
        *'+CPIN:'*)
            # Present but not usable (PIN/PUK required): log the real state.
            cpin_result=$(printf '%s' "$cpin_result" | grep '+CPIN:' | head -1 | tr -d '\r')
            qlog_error "TIER 3: Backup slot $CFG_BACKUP_SIM_SLOT SIM not ready ($cpin_result), falling back"
            sim_failover_fallback || wd_sim_adopt_live_slot
            return 0
            ;;
        *)
            qlog_error "TIER 3: Could not confirm a SIM in backup slot $CFG_BACKUP_SIM_SLOT after 3 attempts ($cpin_reply), falling back"
            sim_failover_fallback || wd_sim_adopt_live_slot
            return 0
            ;;
    esac

    # Read new ICCID for logging
    local new_iccid_raw
    local new_iccid
    local iccid_suffix
    new_iccid_raw=$(qcmd 'AT+QCCID' 2>/dev/null)
    new_iccid=$(printf '%s' "$new_iccid_raw" | grep '+QCCID:' | sed 's/+QCCID: //g' | tr -d '\r ')
    iccid_suffix=$(printf '%s' "$new_iccid" | tail -c 4)
    # Known now, not only at finalize: a reboot mid-cooldown must not raise the
    # "new SIM detected" banner for the backup SIM.
    [ -n "$new_iccid" ] && sim_db_add "$new_iccid"

    qlog_info "TIER 3: Switched to slot $CFG_BACKUP_SIM_SLOT (ICCID: ...$iccid_suffix)"

    # Don't write SIM failover state yet — wait for cooldown to verify connectivity
    # The cooldown handler will check reachability and finalize
    return 0
}

# Fallback: revert SIM to original slot
sim_failover_fallback() {
    qlog_warn "SIM failover fallback: reverting to slot $original_sim_slot"
    append_event "sim_failover" "Watchcat: backup SIM failed, reverting to slot $original_sim_slot" "warning"

    local _rv_iccid
    local _rv_swap_rc

    # Returns 1 with every failover variable intact when the swap back cannot be
    # verified. A caller that does not already hold a failover record follows up
    # with wd_sim_adopt_live_slot: the modem is then still on the backup slot and
    # must not stay unrecorded. wd_swap_slot rc 2 (on the original slot, radio
    # unconfirmed) counts as a completed revert; rc 1 and rc 3 (slot unreadable) do not.
    wd_swap_slot "$original_sim_slot"
    _rv_swap_rc=$?
    case "$_rv_swap_rc" in
        0|2) ;;
        *)
            qlog_error "SIM revert: swap back to slot $original_sim_slot not verified, failover state kept"
            append_event "sim_failover" "Watchcat: could not revert to SIM slot $original_sim_slot — manual check needed" "error"
            return 1
            ;;
    esac

    # Auto-apply profile matching reverted SIM (watchdog_revert)
    _rv_iccid=$(_wd_sim_iccid)
    # Mark the reverted SIM as known so the poller's boot-time swap
    # detector doesn't false-fire on the next reboot.
    if [ -n "$_rv_iccid" ]; then
        sim_db_add "$_rv_iccid"
    fi

    if [ -n "$_rv_iccid" ]; then
        ( . /usr/lib/qmanager/profile_mgr.sh && auto_apply_profile "$_rv_iccid" "watchdog_revert" )
    else
        qlog_info "[watchdog_revert] ICCID query failed after revert, skipping auto-apply"
    fi

    # Restart tower failover daemon
    /etc/init.d/qmanager_tower_failover start 2>/dev/null

    current_sim_slot="$original_sim_slot"
    sim_failover_active="false"
    original_sim_slot="null"
    original_sim_iccid=""
    # A record left by wd_sim_adopt_live_slot (an earlier revert that failed) is stale now.
    wd_failover_clear
    return 0
}

# Called after sim_failover_fallback returned 1: the swap back to the original
# slot was not proven, so the modem is most likely still on the backup slot with
# sim_failover_active=false and no record (a held revert request, a skipped Tier 3
# because backup == current, state lost at a reboot). Adopt what the modem really
# runs: read the live slot, mark the failover active and save the record, so the
# user revert, the auto-failback and a reboot all see it. Returns 1 when nothing
# was adopted (no original slot known, slot unreadable).
wd_sim_adopt_live_slot() {
    local _ad_slot
    local _ad_iccid
    local _ad_reason
    local _ad_json

    WD_ADOPT_SLOT=""
    [ "$sim_failover_active" != "true" ] || return 0
    [ "$original_sim_slot" != "null" ] || return 1

    _ad_slot=$(wd_read_slot)
    case "$_ad_slot" in
        ''|*[!0-9]*)
            qlog_warn "SIM failover: live slot unreadable, state left as it was"
            return 1
            ;;
    esac
    WD_ADOPT_SLOT="$_ad_slot"
    current_sim_slot="$_ad_slot"
    # Back on the original after all (the read-back raced the swap): no failover,
    # and an unconfirmed record left by a Tier 3 swap is stale.
    if [ "$_ad_slot" = "$original_sim_slot" ]; then
        wd_failover_clear
        return 0
    fi

    _ad_iccid=$(_wd_sim_iccid)

    if [ "$recovery_reason" = "quality" ]; then
        _ad_reason="quality_degradation"
    else
        _ad_reason="connectivity_failure"
    fi
    sim_failover_active="true"
    _ad_json=$(_wd_failover_json "$_ad_reason" "$_ad_iccid")
    wd_failover_save "$_ad_json"
    [ -n "$_ad_iccid" ] && sim_db_add "$_ad_iccid"
    last_recheck_time=$(mono_now)
    qlog_warn "SIM failover: revert not confirmed, modem is on slot $current_sim_slot - failover kept active (original slot $original_sim_slot)"
}

# The swap back to the original slot is deferred because the user turned the radio
# off (_cooldown_handle_failure). The modem stays on the backup as a recorded
# failover and the deferral is saved in the record (revert_pending), so a daemon
# restart during airplane mode still completes the swap-back (wd_sim_resume_at_start).
wd_sim_defer_revert() {
    local _dr_pend
    local _dr_json
    wd_sim_revert_pending="true"
    # When it adopts, the record it saves already carries revert_pending.
    wd_sim_adopt_live_slot
    [ -f "$SIM_FAILOVER_FILE" ] || return 0
    _dr_pend=$(jq -r '(.revert_pending) | if . == null then "false" else tostring end' "$SIM_FAILOVER_FILE" 2>/dev/null)
    [ "$_dr_pend" = "true" ] && return 0
    _dr_json=$(jq -c '. + {revert_pending:true}' "$SIM_FAILOVER_FILE" 2>/dev/null)
    [ -n "$_dr_json" ] && wd_failover_save "$_dr_json"
    return 0
}

# Finalize a Tier-3 SIM failover after a successful recovery cooldown. Shared by
# BOTH the reachability and quality success arms so a quality-triggered swap is
# finalized identically (writes $SIM_FAILOVER_FILE, marks sim_failover_active,
# records the SIM, auto-applies the profile, starts the auto-failback clock).
# GUARDED: a no-op unless this episode was a real Tier-3 swap, so either arm may
# call it unconditionally.
finalize_sim_failover() {
    [ "$current_tier" -eq 3 ] || return 0
    [ "$current_sim_slot" != "$original_sim_slot" ] || return 0
    [ "$original_sim_slot" != "null" ] || return 0

    sim_failover_active="true"

    # Reason recorded in the failover file mirrors WHY recovery fired.
    local _fail_reason
    if [ "$recovery_reason" = "quality" ]; then
        _fail_reason="quality_degradation"
    else
        _fail_reason="connectivity_failure"
    fi

    # Read backup ICCID with 3×1s retry — matches sim_failover_fallback pattern.
    local curr_iccid
    curr_iccid=$(_wd_sim_iccid)

    local _fo_json
    _fo_json=$(_wd_failover_json "$_fail_reason" "$curr_iccid")
    wd_failover_save "$_fo_json"

    # Mark this failover SIM as known so the poller's boot-time SIM swap detector
    # treats it as expected (not a physical user swap).
    if [ -n "$curr_iccid" ]; then
        sim_db_add "$curr_iccid"
    fi

    qlog_info "SIM failover state saved: slot $original_sim_slot → $current_sim_slot (reason=$_fail_reason)"
    append_event "sim_failover" "Watchcat: SIM failover confirmed — running on slot $current_sim_slot" "info"

    # Auto-apply profile matching new SIM (watchdog)
    if [ -n "$curr_iccid" ]; then
        ( . /usr/lib/qmanager/profile_mgr.sh && auto_apply_profile "$curr_iccid" "watchdog" )
    fi

    # Start the auto-failback clock from the moment failover is confirmed.
    last_recheck_time=$(mono_now)
}

# Initiate a BLIND recheck of the primary SIM: temporarily swap back to the
# original (primary) slot and let the post-settle health test decide whether to
# stay (failback) or return to the backup. Each call is a real outage — only the
# guarded main-loop call site fires it, and only when opted-in + due.
initiate_primary_recheck() {
    # Defensive precondition re-check (caller guards too).
    [ "$sim_failover_active" = "true" ] || return 0
    [ "$original_sim_slot" != "null" ] || return 0

    # If primary is still bad, this is the slot we return to.
    recheck_return_slot="$current_sim_slot"

    touch "$RECOVERY_FLAG"
    qlog_info "PRIMARY RECHECK: temporary swap-back to primary slot $original_sim_slot"
    append_event "sim_failover" "Watchcat: rechecking primary SIM (slot $original_sim_slot) — temporary swap-back" "info"

    # Verified swap to PRIMARY. On failure stay on the backup (nothing changed),
    # restart the recheck clock and do not enter a settle. rc 2 (on the primary,
    # radio unconfirmed) is on the primary: the settle test below judges the link.
    local _pr_swap_rc
    wd_swap_slot "$original_sim_slot"
    _pr_swap_rc=$?
    if [ "$_pr_swap_rc" -eq 1 ] || [ "$_pr_swap_rc" -eq 3 ]; then
        qlog_error "PRIMARY RECHECK: swap to slot $original_sim_slot not verified, staying on backup"
        append_event "sim_failover" "Watchcat: primary SIM recheck failed (slot swap not verified) — staying on slot $recheck_return_slot" "error"
        last_recheck_time=$(mono_now)
        rm -f "$RECOVERY_FLAG"
        return 0
    fi
    [ "$_pr_swap_rc" -eq 2 ] && qlog_warn "PRIMARY RECHECK: modem is on slot $original_sim_slot, radio not confirmed on"

    # Tentatively on primary now; the post-settle test confirms or reverts.
    current_sim_slot="$original_sim_slot"

    # Enter the settle cooldown. Leave recovery_reason AS-IS so the post-settle
    # health test uses the quality criterion iff the failover was quality-driven.
    # Do NOT clear sim_failover_active yet — finish_cooldown's recheck arm decides.
    primary_recheck_active="true"
    cooldown_remaining="$SIM_SETTLE_SECS"
    state="cooldown"
    qlog_info "Entering primary-recheck settle for ${SIM_SETTLE_SECS}s (reason=$recovery_reason)"
}

# The modem runs on its original (primary) slot for good: drop the failover
# record, learn the SIM and apply its profile (watchdog_failback), give the tower
# locks back, reset the ladder state and return to monitor with a <message> event.
# The caller may then override state with a settle. wd_sim_finish_recheck only.
_wd_sim_failback() {
    local _fb_iccid
    sim_failover_active="false"
    wd_failover_clear

    _fb_iccid=$(_wd_sim_iccid)
    if [ -n "$_fb_iccid" ]; then
        sim_db_add "$_fb_iccid"
        ( . /usr/lib/qmanager/profile_mgr.sh && auto_apply_profile "$_fb_iccid" "watchdog_failback" )
    fi

    # Back on primary — its tower locks are valid again.
    /etc/init.d/qmanager_tower_failover start 2>/dev/null

    append_event "sim_failover" "$1" "info"

    original_sim_slot="null"
    original_sim_iccid=""
    current_tier=0
    failure_counter=0
    quality_breach_counter=0
    _recovery_marker_emitted=""
    last_recheck_time=$(mono_now)
    state="monitor"
    rm -f "$RECOVERY_FLAG"
}

# Primary-recheck settle verdict, called by finish_cooldown when
# primary_recheck_active is "true": a FRESH health read decides failback to the
# primary SIM or a return to the backup slot. Both paths end in return, so the
# caller returns right after this.
wd_sim_finish_recheck() {
    primary_recheck_active="false"

    local _primary_healthy
    _primary_healthy="no"
    if read_ping && [ "$ping_reachable" = "true" ]; then
        if [ "$recovery_reason" = "quality" ]; then
            # Quality failover: primary must also pass the quality criterion.
            if read_quality && ! quality_breached; then
                _primary_healthy="yes"
            fi
        else
            _primary_healthy="yes"
        fi
    fi
    # Stale ping data => read_ping returned 1 => stays "no" (conservative).

    if [ "$_primary_healthy" = "yes" ]; then
        qlog_info "PRIMARY RECHECK: primary SIM healthy — failing back to slot $current_sim_slot"
        _wd_sim_failback "Watchcat: primary SIM healthy again — failed back to slot $current_sim_slot"
        return
    fi

    # Primary still unhealthy — swap BACK to the backup slot.
    qlog_warn "PRIMARY RECHECK: primary SIM still unhealthy — returning to backup slot $recheck_return_slot"
    local _rt_slot
    local _rt_rc
    wd_swap_slot "$recheck_return_slot"
    _rt_rc=$?
    if [ "$_rt_rc" -eq 0 ] || [ "$_rt_rc" -eq 2 ]; then
        current_sim_slot="$recheck_return_slot"
    else
        # Report where the modem really is: possibly still on the primary.
        _rt_slot=$(wd_read_slot)
        if [ "$_rt_slot" = "$original_sim_slot" ]; then
            # The modem stayed on the primary: that is a failback in effect (profile,
            # tower locks, record) followed by the benign settle, not an error.
            qlog_warn "PRIMARY RECHECK: return to backup slot $recheck_return_slot not verified, modem stayed on primary slot $original_sim_slot - treating it as a failback"
            _wd_sim_failback "Watchcat: primary SIM kept — the modem stayed on slot $original_sim_slot"
            revert_settle_active="true"
            recovery_reason="unreachable"
            cooldown_remaining="$SIM_SETTLE_SECS"
            state="cooldown"
            touch "$RECOVERY_FLAG"
            qlog_info "Entering post-recheck settle for ${SIM_SETTLE_SECS}s"
            return
        fi
        qlog_error "PRIMARY RECHECK: return to backup slot $recheck_return_slot not verified"
        append_event "sim_failover" "Watchcat: could not return to backup SIM slot $recheck_return_slot — manual check needed" "error"
        case "$_rt_slot" in
            ''|*[!0-9]*) current_sim_slot="$recheck_return_slot" ;;
            *) current_sim_slot="$_rt_slot" ;;
        esac
    fi
    sim_failover_active="true"

    local _bk_iccid
    _bk_iccid=$(_wd_sim_iccid)

    local _rc_reason
    if [ "$recovery_reason" = "quality" ]; then
        _rc_reason="quality_degradation"
    else
        _rc_reason="connectivity_failure"
    fi

    local _rc_json
    _rc_json=$(_wd_failover_json "$_rc_reason" "$_bk_iccid")
    wd_failover_save "$_rc_json"
    if [ -n "$_bk_iccid" ]; then
        sim_db_add "$_bk_iccid"
    fi

    # On backup again — tower locks are meaningless, keep the daemon stopped.
    # (If the return swap failed and the modem is still on the primary, the
    # error event above says so and the daemon is left running.)
    if [ "$current_sim_slot" = "$recheck_return_slot" ]; then
        /etc/init.d/qmanager_tower_failover stop 2>/dev/null
        append_event "sim_failover" "Watchcat: primary SIM still unhealthy — staying on backup slot $recheck_return_slot" "info"
    fi

    # Restart the interval clock so the next recheck is one full interval away.
    last_recheck_time=$(mono_now)

    # Benign post-swap settle: reuse the revert mechanism so the modem
    # stabilizes on backup WITHOUT escalation. Keep suppression (RECOVERY_FLAG
    # stays touched) during the settle, mirroring check_revert_request.
    revert_settle_active="true"
    recovery_reason="unreachable"
    cooldown_remaining="$SIM_SETTLE_SECS"
    state="cooldown"
    touch "$RECOVERY_FLAG"
    qlog_info "Entering post-recheck backup settle for ${SIM_SETTLE_SECS}s"
    return
}

# =============================================================================
# USER-REQUESTED SIM REVERT
# =============================================================================

# The revert itself, shared by a user request and by the swap-back that was
# deferred while the radio was off. The caller has checked that the modem is
# free to be cycled. Returns 1 with the failover active and the record untouched
# when the swap back is not verified (the request is consumed; the user can ask
# again); 0 otherwise, with the post-revert settle entered when a slot was cycled.
_wd_sim_revert_run() {
    wd_sim_revert_pending="false"
    touch "$RECOVERY_FLAG"
    if ! sim_failover_fallback; then
        rm -f "$RECOVERY_FLAG"
        # A deferred swap-back can arrive with the failover not yet active (the
        # slot was unreadable at deferral): record what the modem really runs.
        wd_sim_adopt_live_slot
        _wd_failover_del revert_pending
        return 1
    fi
    rm -f "$RECOVERY_FLAG"
    wd_failover_clear

    sim_failover_active="false"
    failure_counter=0
    current_tier=0

    # Already on the original slot: nothing was cycled, so no settle.
    if [ "$WD_SWAP_NOOP" = "true" ]; then
        qlog_info "SIM revert: modem already on the original slot, failover record cleared"
        return 0
    fi

    # Enforce the SIM settle floor after the reverse Golden-Rule swap: hold
    # ~90s before the daemon resumes normal connectivity evaluation, just as
    # a forward Tier-3 swap does. Reuse the cooldown state so the UI gets an
    # honest countdown; revert_settle_active marks this as a benign hold so
    # finish_cooldown returns to monitor without recovery escalation.
    revert_settle_active="true"
    recovery_reason="unreachable"
    cooldown_remaining="$SIM_SETTLE_SECS"
    state="cooldown"
    qlog_info "Entering post-revert SIM settle for ${SIM_SETTLE_SECS}s"
    return 0
}

check_revert_request() {
    [ -f "$REVERT_FLAG" ] || return 1
    # B4.1: act only on a root-owned flag; a planted one is dropped
    if ! qm_trusted_file "$REVERT_FLAG"; then
        qlog_warn "Ignoring untrusted SIM revert flag (not root-owned)"
        rm -f "$REVERT_FLAG"
        return 1
    fi

    # Finalized failover — safe to revert now.
    if [ "$sim_failover_active" = "true" ]; then
        # Never revert concurrently with an in-flight recovery/cooldown cycle;
        # the recovery path owns the modem. Leave the flag pending for a later
        # cycle once we are back in a quiescent state.
        if [ "$state" = "recovery" ] || [ "$state" = "cooldown" ]; then
            qlog_info "SIM revert requested but $state in progress — deferring to next cycle"
            return 1
        fi

        # A maintenance lock, airplane mode or an SSR hold owns the modem too:
        # a swap now would cycle the radio under it. check_locked is read live
        # because the loop sets state="locked" only after this call.
        if check_locked || [ "$state" = "locked" ] || [ "$state" = "radio_off" ] || [ "$state" = "ssr_hold" ]; then
            qlog_info "SIM revert requested but modem is busy (state=$state) — deferring"
            return 1
        fi

        qlog_info "User requested SIM revert to slot $original_sim_slot"
        rm -f "$REVERT_FLAG"
        append_event "sim_failover" "Watchcat: reverting to original SIM slot $original_sim_slot (user request)" "info"

        _wd_sim_revert_run
        return $?
    fi

    # No finalized failover. If a Tier-3 swap is mid-flight (slot already moved to
    # the backup but cooldown hasn't finalized sim_failover_active yet), KEEP the
    # request pending so it is consumed on a later cycle after finalization —
    # do NOT silently delete it.
    if [ "$original_sim_slot" != "null" ] && [ "$current_sim_slot" != "$original_sim_slot" ]; then
        qlog_info "SIM revert requested while a swap is mid-flight — keeping request pending"
        return 1
    fi

    # Genuinely nothing to revert (no failover active, no swap in progress).
    rm -f "$REVERT_FLAG"
    return 1
}

# Called by main() when the radio_off arm sees AT+CFUN=1 again. A Tier 3 swap-back
# that _cooldown_handle_failure deferred because the user had turned the radio off
# (wd_sim_revert_pending) runs now, through the same path as a user revert.
wd_sim_on_radio_back() {
    [ "$wd_sim_revert_pending" = "true" ] || return 0
    wd_sim_revert_pending="false"
    # sim_failover_active is not required: the deferral may have left the slot
    # unreadable, so the failover was assumed and only the record names it.
    if [ "$original_sim_slot" = "null" ] || [ "$current_sim_slot" = "$original_sim_slot" ]; then
        _wd_failover_del revert_pending
        return 0
    fi
    qlog_info "Radio is back on: completing the SIM swap-back to slot $original_sim_slot deferred during airplane mode"
    _wd_sim_revert_run
}

# Resume a Tier-3 failover recorded before this daemon start, called by main()
# after the boot settle (the modem answers by then). The record is read from
# /tmp, or from the flash copy after a reboot, and trusted only when the live
# slot matches it: a mismatch clears both copies, an UNREADABLE slot keeps both
# and activates nothing (a blank read must never delete a valid record).
wd_sim_resume_at_start() {
    local _rs_src
    local _rs_cand
    local sf_active_val
    local _sf_orig
    local _sf_curr
    local _sf_conf
    local _sf_pend
    local _live_slot

    # B4.1: trust a record only when root-owned; otherwise drop that copy.
    _rs_src=""
    for _rs_cand in "$SIM_FAILOVER_FILE" "$SIM_FAILOVER_DURABLE"; do
        [ -e "$_rs_cand" ] || [ -L "$_rs_cand" ] || continue
        if ! qm_trusted_file "$_rs_cand"; then
            qlog_warn "Ignoring untrusted SIM failover file $_rs_cand (not root-owned) - removing"
            rm -f "$_rs_cand"
            continue
        fi
        # First copy that parses wins; /tmp is newer than flash when both exist.
        sf_active_val=$(jq -r '(.active) | if . == null then "false" else tostring end' "$_rs_cand" 2>/dev/null)
        if [ -n "$sf_active_val" ]; then
            _rs_src="$_rs_cand"
            break
        fi
    done
    [ -n "$_rs_src" ] || return 0
    [ "$sf_active_val" = "true" ] || return 0

    _sf_orig=$(jq -r '(.original_slot) | if . == null then "null" else tostring end' "$_rs_src" 2>/dev/null)
    _sf_curr=$(jq -r '(.current_slot) | if . == null then "null" else tostring end' "$_rs_src" 2>/dev/null)
    _sf_conf=$(jq -r '(.confirmed) | if . == null then "true" else tostring end' "$_rs_src" 2>/dev/null)
    _sf_pend=$(jq -r '(.revert_pending) | if . == null then "false" else tostring end' "$_rs_src" 2>/dev/null)
    _live_slot=$(wd_read_slot)

    if [ -z "$_live_slot" ]; then
        qlog_warn "SIM failover record found but the live slot is unreadable - keeping it, not resuming"
        return 0
    fi

    if [ "$_live_slot" = "$_sf_curr" ]; then
        sim_failover_active="true"
        original_sim_slot="$_sf_orig"
        current_sim_slot="$_sf_curr"
        # Restore the original ICCID so a later recheck/return-to-backup
        # rewrites the failover record honestly.
        original_sim_iccid=$(jq -r '(.original_iccid) | if . == null then "" else tostring end' "$_rs_src" 2>/dev/null)
        # Keep both copies in step: the poller reads /tmp, a reboot reads flash.
        if [ "$_rs_src" = "$SIM_FAILOVER_DURABLE" ]; then
            qm_atomic_write "$SIM_FAILOVER_FILE" < "$_rs_src"
        elif [ ! -f "$SIM_FAILOVER_DURABLE" ]; then
            qm_durable_write "$SIM_FAILOVER_DURABLE" < "$_rs_src"
        fi
        # Start the auto-failback clock from boot-resume so a recheck is at
        # most one interval away (not immediately on boot).
        last_recheck_time=$(mono_now)
        qlog_info "Resumed SIM failover state: slot $original_sim_slot → $current_sim_slot (verified)"
        # A record saved by a Tier 3 swap the cooldown never judged: the modem is
        # on the backup slot, so it is a failover now.
        [ "$_sf_conf" = "false" ] && _wd_failover_del confirmed
        # A swap-back deferred for airplane mode before the restart: run it when
        # the radio is on, else wait for it in radio_off. Under a maintenance
        # lock it only stays pending: wd_sim_on_unlock completes it.
        if [ "$_sf_pend" = "true" ]; then
            if check_locked; then
                wd_sim_revert_pending="true"
            elif [ "$(wd_cfun_now)" = "1" ]; then
                qlog_info "Completing the SIM swap-back to slot $original_sim_slot deferred before the restart"
                _wd_sim_revert_run
            else
                wd_sim_revert_pending="true"
                wd_enter_radio_off
            fi
        fi
    else
        qlog_warn "SIM failover file recorded slot $_sf_curr but modem is on slot $_live_slot — clearing stale state"
        wd_failover_clear
    fi
}

# Later passes: a failover record that startup could not resume (live slot
# unreadable) is retried every WD_RESUME_RETRY_SECS while it exists and no failover
# is active, only when idle in monitor (a recovery owns the modem otherwise). The
# first call just arms the timer: the startup attempt has only just run.
wd_sim_resume_retry() {
    local _rr_now
    [ "$sim_failover_active" != "true" ] || return 0
    [ "$state" = "monitor" ] || return 0
    [ -e "$SIM_FAILOVER_FILE" ] || [ -e "$SIM_FAILOVER_DURABLE" ] || return 0
    _rr_now=$(mono_now)
    case "$_rr_now" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$_wd_resume_next" -eq 0 ]; then
        _wd_resume_next=$((_rr_now + WD_RESUME_RETRY_SECS))
        return 0
    fi
    [ "$_rr_now" -ge "$_wd_resume_next" ] || return 0
    _wd_resume_next=$((_rr_now + WD_RESUME_RETRY_SECS))
    wd_sim_resume_at_start
}

# SIM clean-up on LOCKED exit, called by main() right after the generic LOCKED
# reset: reverts an unconfirmed Tier-3 swap and re-arms an interrupted primary
# recheck.
wd_sim_on_unlock() {
    # A swap-back deferred for airplane mode survives a lock (the flag was left
    # alone on LOCKED entry): run it when the radio is on, else wait for it in
    # radio_off. It takes over from the unconfirmed-swap revert below, which
    # would cycle a radio the user may have turned off.
    if [ "$wd_sim_revert_pending" = "true" ]; then
        if [ "$(wd_cfun_now)" = "1" ]; then
            wd_sim_on_radio_back
        else
            wd_enter_radio_off
        fi
    # Entering LOCKED mid-cooldown abandons a Tier-3 swap the cooldown never
    # confirmed: the modem stays on the backup SIM with no failover record,
    # a revert request waits forever and the next outage skips Tier 3
    # (backup == current). Revert it now, as an unrestored Tier 3 is. A Tier 3
    # that aborted before the swap leaves current_sim_slot "null": no revert. Not
    # on LOCKED entry: the lock holder owns the modem until here.
    elif [ "$sim_failover_active" != "true" ] && [ "$original_sim_slot" != "null" ] && [ "$current_sim_slot" != "null" ] && [ "$current_sim_slot" != "$original_sim_slot" ]; then
        qlog_warn "LOCKED exit: unconfirmed Tier 3 swap on slot $current_sim_slot, reverting to slot $original_sim_slot"
        touch "$RECOVERY_FLAG"
        if sim_failover_fallback; then
            revert_settle_active="true"
            recovery_reason="unreachable"
            cooldown_remaining="$SIM_SETTLE_SECS"
            state="cooldown"
            qlog_info "Entering post-revert SIM settle for ${SIM_SETTLE_SECS}s"
        else
            rm -f "$RECOVERY_FLAG"
            wd_sim_adopt_live_slot
        fi
    fi

    # LOCKED during a primary-recheck settle left the modem on the primary
    # slot with sim_failover_active=true and the record still naming the
    # backup. Re-arm the settle so finish_cooldown's recheck arm decides
    # failback or return-to-backup from a fresh health read.
    if [ "$recheck_interrupted" = "true" ]; then
        recheck_interrupted="false"
        if [ "$sim_failover_active" = "true" ] && [ "$original_sim_slot" != "null" ] && [ "$current_sim_slot" = "$original_sim_slot" ] && [ "$recheck_return_slot" != "null" ]; then
            qlog_warn "LOCKED exit: primary recheck was interrupted on slot $current_sim_slot, re-arming its settle for ${SIM_SETTLE_SECS}s"
            touch "$RECOVERY_FLAG"
            primary_recheck_active="true"
            cooldown_remaining="$SIM_SETTLE_SECS"
            state="cooldown"
        fi
    fi
}

WD_SIM_LOADED=1
