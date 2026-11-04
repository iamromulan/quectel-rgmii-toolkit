#!/bin/sh
# =============================================================================
# alert_engine.sh — Centralized Connection-Alert Engine for QManager
# =============================================================================
# ONE downtime state machine + dispatcher, replacing the two duplicated state
# machines that used to live in sms_alerts.sh::check_sms_alert and
# email_alerts.sh::check_email_alert. Sourced into qmanager_poller and invoked
# once per cycle from the always-every-cycle local block (before any AT work),
# so alert detection keeps running at the 2s base cadence regardless of the
# adaptive-polling tier.
#
# This library sources NOTHING itself — the poller sources, in order:
#   qlog.sh (mono_now, qlog_*) -> events.sh -> email_alerts.sh -> sms_alerts.sh
#   -> alert_routing.sh -> alert_engine.sh
# The engine reads globals owned by those libs at call time:
#   ev_link_state                                   (events.sh detector)
#   conn_internet_available / conn_during_recovery  (poller; reboot delivery only)
#   CQ_ALERT_AFTER_MIN / cq_alert_after_min         (conn_state.sh, the one wait)
#   _sa_enabled / _ea_enabled                       (channel libs)
#   alert_route_enabled / alert_routing_load        (alert_routing.sh)
#   sms_alert_emit / email_alert_emit               (channel libs)
#
# Signal source [guardrail 1]: the events.sh detector's ev_link_state
#   (detect_data_connection_events, earlier in the same cycle). The engine has
#   no edge detector of its own, so the Activity feed and the channels can
#   never disagree about an outage. Never service_status / registration state.
# Debounce [guardrail 2]: ONE wait for every channel (alert_after_min, owned
#   by Connection Quality), measured with the MONOTONIC clock (mono_now, the
#   same clock ping.json's .mono uses), NOT wall-clock epoch. A NITZ clock-step
#   during an SSR-driven outage therefore cannot corrupt the timer.
# Recovery [guardrail 3]: a watchdog recovery does not
#   freeze the outage machine; the SMS lib's rc 2 ("not registered") retries a
#   send made during a CFUN cycle. Reboot delivery is still held mid-recovery.
# =============================================================================

[ -n "$_ALERT_ENGINE_LOADED" ] && return 0
_ALERT_ENGINE_LOADED=1

[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

# _ae_store_boot_id ID — persist the last seen boot_id. Durable replace, so a
# crash right after a reboot is detected cannot leave the file empty (which
# would read as "first boot ever" and swallow the next reboot alert).
_ae_store_boot_id() {
    if command -v qm_durable_write >/dev/null 2>&1; then
        printf '%s\n' "$1" | qm_durable_write "$_AE_BOOT_ID_FILE" 2>/dev/null
    else
        printf '%s\n' "$1" > "$_AE_BOOT_ID_FILE" 2>/dev/null
    fi
}

# --- Reload flags + suppression sentinels (literal paths — the engine does not
# --- depend on the channel libs having been sourced to evaluate these) -------
_AE_SMS_RELOAD="/tmp/qmanager_sms_reload"
_AE_EMAIL_RELOAD="/tmp/qmanager_email_reload"
_AE_ROUTING_RELOAD="/tmp/qmanager_alert_routing_reload"

# --- Reboot-alert detection + delivery (a separate one-shot path) ------------
# boot_id is a per-boot kernel UUID: stable within a boot, regenerated on every
# real reboot, and immune to NITZ/ntpd clock-steps and baseband SSRs (an SSR
# does not reset uptime or regenerate boot_id). It is the reboot detector.
_AE_BOOT_ID_SRC="/proc/sys/kernel/random/boot_id"
# Persisted on ubifs so it survives the reboot we are trying to detect.
_AE_BOOT_ID_FILE="/etc/qmanager/last_boot_id"
# Staged pending alert lives in tmpfs on PURPOSE: a real reboot wipes it (and we
# re-stage fresh on the next boot), while a bare procd respawn of the poller —
# same boot_id — keeps an unsent pending so delivery still happens.
_AE_REBOOT_PENDING="/tmp/qmanager_reboot_pending.json"
# Shared reboot ledger (see qlog.sh::record_planned_reboot + watchcat tier4).
_AE_CRASH_LOG="/etc/qmanager/crash.log"
# Classification window (seconds): a planned reboot writes its breadcrumb, then
# the kernel takes tens of seconds to come back, so the breadcrumb epoch sits a
# short time before the new boot epoch. Generous enough to absorb a slow boot
# and modest clock drift; narrow enough not to swallow a prior reboot's row.
_AE_REBOOT_WINDOW=300
# Storm coalescer: MORE than this many all-cause reboots in the last hour trips
# a single "reboot-looping" message instead of one alert per boot (SMS costs
# money). Suppressed for the rest of the hour via a mono-stamped marker.
_AE_REBOOT_STORM_THRESHOLD=3
_AE_REBOOT_STORM_FLAG="/tmp/qmanager_reboot_storm_hour"
# A wall clock below this is still in the 1970 boot window (NITZ/ntpd not stepped
# yet): classifying then compares crash.log against a bogus boot epoch and writes
# a 1970 row into the ledger, so detection holds until the clock passes it.
_AE_SANE_EPOCH=1700000000
# Boot id seen changed while the clock was unset; retried each cycle (see below).
_ae_boot_unresolved=""

# --- State (poller-process memory, module scope) -----------------------------
# _ae_outage_active     : "0" idle / "1" outage in progress
# _ae_outage_start_mono : mono_now at outage start (monotonic seconds)
# _ae_<ch>_armed        : outage exceeded THIS channel's threshold (warrants a
#                         restored message even if the lost message never sent)
# _ae_<ch>_lost_sent    : the connection_lost message attempt for THIS channel
#                         is done (sent or terminally failed) — don't re-attempt
_ae_outage_active="0"
_ae_outage_start_mono=0
_ae_sms_armed="0"
_ae_email_armed="0"
_ae_sms_lost_sent="0"
_ae_email_lost_sent="0"

# --- Last cleared outage (published as connectivity.last_outage_*) -----------
# _ae_last_outage_s        : total seconds of the most recently CLEARED outage
#                            ("" until one clears this boot)
# _ae_last_outage_end_mono : mono_now when it cleared; the poller publishes the
#                            age as mono delta, so clock steps cannot skew it
# _ae_last_outage_wan4/6  : the bearer's WAN addresses read when it cleared
# _ae_last_outage_wan_changed : "true" / "false" against the address seen just
#                            before the outage, "" when either side is unknown
# Kept in tmpfs on purpose: a poller respawn reloads it (same boot, same mono
# base), a reboot clears it along with the mono clock it is anchored to.
# File format: "<seconds> <end_mono> <changed|-> <wan4|-> <wan6|->".
_AE_LAST_OUTAGE_FILE="/tmp/qmanager_last_outage"
_ae_last_outage_s=""
_ae_last_outage_end_mono=""
_ae_last_outage_wan4=""
_ae_last_outage_wan6=""
_ae_last_outage_wan_changed=""

# --- WAN address tracking (kernel routing table only, never AT) --------------
# The poller's t2_wan_* only refresh when the on-demand radio details are read,
# so they cannot tell whether a reconnect changed the IP. The default route's
# source address can: once probes answer again, the bearer holds its new one.
# _ae_wan_seen4/6 : last addresses seen while the link was up, refreshed at most
#                   every _AE_WAN_SEEN_EVERY seconds (two `ip` forks)
# _ae_pre_wan4/6  : the addresses the outage started from
_AE_WAN_SEEN_EVERY=30
_ae_wan_seen4=""
_ae_wan_seen6=""
_ae_wan_seen_mono=""
_ae_pre_wan4=""
_ae_pre_wan6=""

# _ae_wan_read — the data bearer's current WAN addresses into _AE_WAN4 and
# _AE_WAN6 (empty when there is none or the value is not address-shaped).
_ae_wan_read() {
    local _ae_l
    local _ae_dev
    _AE_WAN4=""
    _AE_WAN6=""
    _ae_l=$(ip -4 route show default 2>/dev/null | head -n 1)
    case "$_ae_l" in
        *" src "*)
            _AE_WAN4="${_ae_l##* src }"
            _AE_WAN4="${_AE_WAN4%% *}"
            ;;
    esac
    case "$_AE_WAN4" in *[!0-9.]*|'') _AE_WAN4="" ;; esac
    _ae_l=$(ip -6 route show default 2>/dev/null | head -n 1)
    case "$_ae_l" in
        *" dev "*)
            _ae_dev="${_ae_l##* dev }"
            _ae_dev="${_ae_dev%% *}"
            _ae_l=$(ip -6 -o addr show dev "$_ae_dev" scope global 2>/dev/null | head -n 1)
            case "$_ae_l" in
                *" inet6 "*)
                    _AE_WAN6="${_ae_l##* inet6 }"
                    _AE_WAN6="${_AE_WAN6%%/*}"
                    ;;
            esac
            ;;
    esac
    case "$_AE_WAN6" in *[!0-9a-fA-F:]*|'') _AE_WAN6="" ;; esac
    return 0
}

# _ae_wan_seen_refresh [force] — refresh the last-seen addresses while the link
# is up. An empty read never overwrites a known address.
_ae_wan_seen_refresh() {
    local _ae_m
    _ae_m=$(mono_now)
    if [ "$1" != "force" ] && [ -n "$_ae_wan_seen_mono" ] \
        && [ $((_ae_m - _ae_wan_seen_mono)) -lt "$_AE_WAN_SEEN_EVERY" ]; then
        return 0
    fi
    _ae_wan_seen_mono="$_ae_m"
    _ae_wan_read
    [ -n "$_AE_WAN4" ] && _ae_wan_seen4="$_AE_WAN4"
    [ -n "$_AE_WAN6" ] && _ae_wan_seen6="$_AE_WAN6"
    return 0
}

# _ae_wan_cmp OLD NEW — prints true/false, or nothing when either is empty.
_ae_wan_cmp() {
    [ -n "$1" ] && [ -n "$2" ] || return 0
    if [ "$1" = "$2" ]; then echo false; else echo true; fi
}

# _ae_last_outage_load — restore the last cleared outage after a poller
# respawn. Garbage (or an end stamp ahead of the current uptime) is ignored;
# the older two-field file still loads, without the WAN fields.
_ae_last_outage_load() {
    local _ae_d
    local _ae_e
    local _ae_c
    local _ae_w4
    local _ae_w6
    local _ae_rest
    [ -f "$_AE_LAST_OUTAGE_FILE" ] || return 0
    { read -r _ae_d _ae_e _ae_c _ae_w4 _ae_w6 _ae_rest < "$_AE_LAST_OUTAGE_FILE"; } 2>/dev/null
    case "$_ae_d" in ''|*[!0-9]*) return 0 ;; esac
    case "$_ae_e" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_ae_e" -le "$(mono_now)" ] || return 0
    _ae_last_outage_s="$_ae_d"
    _ae_last_outage_end_mono="$_ae_e"
    case "$_ae_c" in true|false) _ae_last_outage_wan_changed="$_ae_c" ;; esac
    case "$_ae_w4" in -|''|*[!0-9.]*) ;; *) _ae_last_outage_wan4="$_ae_w4" ;; esac
    case "$_ae_w6" in -|''|*[!0-9a-fA-F:]*) ;; *) _ae_last_outage_wan6="$_ae_w6" ;; esac
}

# =============================================================================
# alert_engine_init — reset state to idle + prime routing cache
# =============================================================================
alert_engine_init() {
    _ae_outage_active="0"
    _ae_outage_start_mono=0
    _ae_sms_armed="0"
    _ae_email_armed="0"
    _ae_sms_lost_sent="0"
    _ae_email_lost_sent="0"
    _ae_last_outage_load
    _ae_wan_seen_refresh force
    alert_routing_load
    _ae_resolve_wait
    qlog_info "Alert engine initialized (wait=${CQ_ALERT_AFTER_MIN:-5}m)"
}

# --- Per-channel accessors (2 channels only; case dispatch avoids eval) -------
# Master-enable, read from the channel libs' cached config globals.
_ae_channel_enabled() {
    case "$1" in
        sms)   [ "$_sa_enabled" = "true" ] ;;
        email) [ "$_ea_enabled" = "true" ] ;;
        *)     return 1 ;;
    esac
}

# Re-resolve the single wait (CQ_ALERT_AFTER_MIN, conn_state.sh): at init, at
# outage start and on any config reload.
_ae_resolve_wait() {
    command -v cq_alert_after_min >/dev/null 2>&1 && cq_alert_after_min
    return 0
}

# The one wait in SECONDS, the same for every channel; 300 on garbage.
_ae_wait_secs() {
    case "${CQ_ALERT_AFTER_MIN:-}" in
        ''|*[!0-9]*|0) echo 300 ;;
        *) echo $(( CQ_ALERT_AFTER_MIN * 60 )) ;;
    esac
}

# Marker get/set. Getters run in $(...) subshells (read-only, safe). Setters
# must be called in the main shell (not a subshell) so the assignment persists.
_ae_get_armed()     { case "$1" in sms) echo "$_ae_sms_armed" ;; email) echo "$_ae_email_armed" ;; esac; }
_ae_set_armed()     { case "$1" in sms) _ae_sms_armed="$2" ;;   email) _ae_email_armed="$2" ;;   esac; }
_ae_get_lost_sent() { case "$1" in sms) echo "$_ae_sms_lost_sent" ;; email) echo "$_ae_email_lost_sent" ;; esac; }
_ae_set_lost_sent() { case "$1" in sms) _ae_sms_lost_sent="$2" ;;   email) _ae_email_lost_sent="$2" ;;   esac; }

# Dispatch a send to the right channel lib. Returns the emit's rc:
#   0 = sent, 1 = attempted but failed (terminal), 2 = not ready (retry later).
_ae_channel_emit() {
    case "$1" in
        sms)   sms_alert_emit "$2" "$3" ;;
        email) email_alert_emit "$2" "$3" ;;
        *)     return 1 ;;
    esac
}

# =============================================================================
# alert_engine_check — per-cycle entry point (replaces check_*_alert)
# =============================================================================
alert_engine_check() {
    local _ae_ch

    # --- 1. Reload gate: channel libs re-read their config; routing reloads ---
    if [ -f "$_AE_SMS_RELOAD" ]; then
        rm -f "$_AE_SMS_RELOAD"
        _sa_read_config 2>/dev/null
        _ae_resolve_wait
        qlog_info "Alert engine: SMS channel config reloaded (enabled=$_sa_enabled wait=${CQ_ALERT_AFTER_MIN:-5}m)"
    fi
    if [ -f "$_AE_EMAIL_RELOAD" ]; then
        rm -f "$_AE_EMAIL_RELOAD"
        _ea_read_config 2>/dev/null
        _ae_resolve_wait
        qlog_info "Alert engine: email channel config reloaded (enabled=$_ea_enabled wait=${CQ_ALERT_AFTER_MIN:-5}m)"
    fi
    if [ -f "$_AE_ROUTING_RELOAD" ]; then
        alert_routing_load
        qlog_info "Alert engine: routing reloaded"
    fi

    # --- 1b. A reboot detected before the clock was set: retry once it is -----
    # Ahead of the suppression gate: this records the reboot, it sends nothing.
    if [ -n "$_ae_boot_unresolved" ] && _ae_clock_sane; then
        qlog_info "Alert engine: clock set, classifying the held reboot"
        alert_engine_reboot_detect
    fi

    # --- 2. Post-recovery reboot alert (separate one-shot path) --------------
    # NOT part of the outage state machine — a reboot has no outage window.
    # Held during watchdog recovery churn and on stale ping data. Cheap
    # early-out when there is no staged pending file (the common case).
    if [ "$conn_during_recovery" != "true" ]; then
        case "$conn_internet_available" in
            true|false) _ae_reboot_check ;;
        esac
    fi

    # --- 3. Signal source [guardrail 1]: the events.sh detector --------------
    # ev_link_state is decided once per cycle by detect_data_connection_events
    # (ICMP reachability only). "" = stale/unknown: a running outage is left
    # untouched and nothing new starts. A watchdog recovery no longer freezes
    # the engine, so an outage the watchdog fixes is still alerted.
    case "${ev_link_state:-}" in
        down) _ae_handle_down ;;
        up)
            _ae_handle_up
            _ae_wan_seen_refresh
            ;;
    esac
    return 0
}

# =============================================================================
# _ae_handle_down — internet is DOWN this cycle
# =============================================================================
_ae_handle_down() {
    local _ae_ch
    local _ae_now
    local _ae_elapsed
    local _ae_thr
    local _ae_rc

    # Start a new outage on the leading edge.
    if [ "$_ae_outage_active" != "1" ]; then
        _ae_outage_active="1"
        _ae_outage_start_mono=$(mono_now)
        # The bearer may already have lost its address by the time the
        # detector calls the outage; fall back to the last one seen up.
        _ae_wan_read
        _ae_pre_wan4="${_AE_WAN4:-$_ae_wan_seen4}"
        _ae_pre_wan6="${_AE_WAN6:-$_ae_wan_seen6}"
        _ae_sms_armed="0"
        _ae_email_armed="0"
        _ae_sms_lost_sent="0"
        _ae_email_lost_sent="0"
        _ae_resolve_wait
        qlog_info "Alert engine: outage started (mono=$_ae_outage_start_mono wait=${CQ_ALERT_AFTER_MIN:-5}m)"
    fi

    # Elapsed via the MONOTONIC clock [guardrail 2] — immune to NITZ steps.
    _ae_now=$(mono_now)
    _ae_elapsed=$(( _ae_now - _ae_outage_start_mono ))
    [ "$_ae_elapsed" -lt 0 ] && _ae_elapsed=0

    for _ae_ch in sms email; do
        _ae_channel_enabled "$_ae_ch" || continue
        _ae_thr=$(_ae_wait_secs)
        [ "$_ae_elapsed" -ge "$_ae_thr" ] || continue

        # Crossed this channel's threshold → arm it. Arming is independent of
        # capability, so email arms here (warranting a recovery email) even
        # though it never sends a connection_lost message.
        _ae_set_armed "$_ae_ch" "1"

        # The connection_lost message goes out only for a routed, capable
        # channel (SMS only). Skip if not routed/capable or already attempted.
        alert_route_enabled connection_lost "$_ae_ch" || continue
        [ "$(_ae_get_lost_sent "$_ae_ch")" = "1" ] && continue

        _ae_channel_emit "$_ae_ch" connection_lost "$_ae_elapsed"
        _ae_rc=$?
        # rc 2 = "not ready" (SMS modem not registered, or busy) — leave the
        # marker clear so we retry next cycle without burning a send attempt.
        # rc 0 (sent) or rc 1 (registered but the qsms send failed) are terminal.
        if [ "$_ae_rc" != "2" ]; then
            _ae_set_lost_sent "$_ae_ch" "1"
        fi
    done
}

# =============================================================================
# _ae_handle_up — internet is UP this cycle
# =============================================================================
_ae_handle_up() {
    local _ae_ch
    local _ae_now
    local _ae_total

    # Nothing to do unless we were tracking an outage.
    [ "$_ae_outage_active" = "1" ] || return 0

    _ae_now=$(mono_now)
    _ae_total=$(( _ae_now - _ae_outage_start_mono ))
    [ "$_ae_total" -lt 0 ] && _ae_total=0

    # Fire a restored message for every channel that was armed AND is routed
    # for connection_restored. SMS armed <=> its outage crossed threshold (which
    # also covers the "a down SMS was sent" case); email armed <=> the outage
    # exceeded email's threshold. Restored is fire-once — no retry semantics.
    for _ae_ch in sms email; do
        _ae_channel_enabled "$_ae_ch" || continue
        [ "$(_ae_get_armed "$_ae_ch")" = "1" ] || continue
        alert_route_enabled connection_restored "$_ae_ch" || continue
        _ae_channel_emit "$_ae_ch" connection_restored "$_ae_total"
    done

    # Publish the cleared outage before the reset discards _ae_total. Probes
    # answer again, so the bearer holds the address it reconnected with.
    _ae_wan_read
    _ae_last_outage_s="$_ae_total"
    _ae_last_outage_end_mono="$_ae_now"
    _ae_last_outage_wan4="$_AE_WAN4"
    _ae_last_outage_wan6="$_AE_WAN6"
    _ae_last_outage_wan_changed=$(_ae_wan_cmp "$_ae_pre_wan4" "$_AE_WAN4")
    [ -z "$_ae_last_outage_wan_changed" ] && \
        _ae_last_outage_wan_changed=$(_ae_wan_cmp "$_ae_pre_wan6" "$_AE_WAN6")
    [ -n "$_AE_WAN4" ] && _ae_wan_seen4="$_AE_WAN4"
    [ -n "$_AE_WAN6" ] && _ae_wan_seen6="$_AE_WAN6"
    _ae_wan_seen_mono="$_ae_now"
    _ae_pre_wan4=""
    _ae_pre_wan6=""
    if command -v qm_atomic_write >/dev/null 2>&1; then
        printf '%s %s %s %s %s\n' "$_ae_total" "$_ae_now" \
            "${_ae_last_outage_wan_changed:--}" "${_AE_WAN4:--}" "${_AE_WAN6:--}" \
            | qm_atomic_write "$_AE_LAST_OUTAGE_FILE" 2>/dev/null
    else
        printf '%s %s %s %s %s\n' "$_ae_total" "$_ae_now" \
            "${_ae_last_outage_wan_changed:--}" "${_AE_WAN4:--}" "${_AE_WAN6:--}" \
            > "$_AE_LAST_OUTAGE_FILE" 2>/dev/null
    fi

    # Reset all outage state.
    _ae_outage_active="0"
    _ae_outage_start_mono=0
    _ae_sms_armed="0"
    _ae_email_armed="0"
    _ae_sms_lost_sent="0"
    _ae_email_lost_sent="0"
    qlog_info "Alert engine: outage cleared (total=${_ae_total}s)"
}

# =============================================================================
# REBOOT ALERT — detection (once at startup) + delivery (once per boot)
# =============================================================================
# Fires ONE alert per real device boot, delivered post-recovery (at the reboot
# instant all of userspace is dead — both channels are undeliverable, so the
# alert can only ever go out once connectivity is back). Three causes:
#   watchdog  — the watchcat tier-4 escalation reboot (crash.log tier4 row)
#   user      — any planned reboot (button / scheduled / IPPT / IMEI / MBN /
#               install-update); all fold into "user" via a crash.log user row
#   unplanned — a boot with NO matching recent breadcrumb (power loss / firmware
#               AP-hang). Inferred purely from the ABSENCE of a breadcrumb; this
#               device exposes no positive hardware signal for it.
# Routing defaults OFF on both channels (opt-in), but detection + the ledger
# record every boot regardless of routing.

# _ae_reboot_count_last_hour — ALL-cause reboot count in the trailing hour.
# Distinct from watchcat's count_recent_reboots (tier4-only, for the token
# bucket). Every real boot leaves exactly one crash.log row — planned rows are
# written pre-reboot by record_planned_reboot, watchdog rows by watchcat, and an
# inferred unplanned row is written post-boot by alert_engine_reboot_detect — so
# this count tracks the true reboot rate for the storm coalescer.
_ae_reboot_count_last_hour() {
    local _f="$_AE_CRASH_LOG"
    local _now
    local _cut
    local _n
    [ -f "$_f" ] || { echo 0; return; }
    _now=$(date +%s)
    _cut=$(( _now - 3600 ))
    _n=$(awk -v c="$_cut" -F'|' '$1 ~ /^[0-9]+$/ && $1 >= c { n++ } END { print n+0 }' "$_f" 2>/dev/null)
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    echo "$_n"
}

# _ae_classify_reboot <boot_epoch> — newest in-window crash.log reason → bucket.
_ae_classify_reboot() {
    local _be="$1"
    local _reason
    [ -f "$_AE_CRASH_LOG" ] || { echo "unplanned"; return; }

    # crash.log is chronological (appended), so the LAST in-window row is the
    # newest. awk regex is fine here (only jq lacks Oniguruma on this device).
    _reason=$(awk -v be="$_be" -v win="$_AE_REBOOT_WINDOW" -F'|' '
        $1 ~ /^[0-9]+$/ {
            d = $1 - be; if (d < 0) d = -d;
            if (d <= win) { r = $3 }
        }
        END { print r }
    ' "$_AE_CRASH_LOG" 2>/dev/null)

    case "$_reason" in
        tier4_escalation) echo "watchdog" ;;
        user)             echo "user" ;;
        *)                echo "unplanned" ;;
    esac
}

# _ae_stage_reboot_pending <boot_id> <cause> — write the tmpfs pending file.
_ae_stage_reboot_pending() {
    local _bid="$1"
    local _cause="$2"
    local _mono
    _mono=$(mono_now)
    jq -n -c \
        --arg bid "$_bid" \
        --arg cause "$_cause" \
        --argjson mono "$_mono" \
        '{boot_id: $bid, cause: $cause, detected_mono: $mono, sms_sent: false, email_sent: false}' \
        > "$_AE_REBOOT_PENDING" 2>/dev/null
}

# _ae_reboot_mark_sent <channel> — flip the per-channel flag in the pending file
# (atomic temp+mv; the file is tiny). Never `//` on the sibling boolean.
_ae_reboot_mark_sent() {
    local _ch="$1"
    local _key
    local _tmp
    case "$_ch" in
        sms)   _key="sms_sent" ;;
        email) _key="email_sent" ;;
        *)     return 1 ;;
    esac
    [ -f "$_AE_REBOOT_PENDING" ] || return 1
    _tmp="${_AE_REBOOT_PENDING}.tmp.$$"
    if jq -c --arg k "$_key" '.[$k] = true' "$_AE_REBOOT_PENDING" > "$_tmp" 2>/dev/null; then
        mv "$_tmp" "$_AE_REBOOT_PENDING" 2>/dev/null || rm -f "$_tmp"
    else
        rm -f "$_tmp"
    fi
}

# _ae_storm_flag_fresh — is the storm-suppression marker < 1h old (monotonic)?
_ae_storm_flag_fresh() {
    local _t
    local _age
    [ -f "$_AE_REBOOT_STORM_FLAG" ] || return 1
    _t=$(cat "$_AE_REBOOT_STORM_FLAG" 2>/dev/null)
    case "$_t" in ''|*[!0-9]*) return 1 ;; esac
    _age=$(( $(mono_now) - _t ))
    [ "$_age" -ge 0 ] && [ "$_age" -lt 3600 ]
}

# _ae_reboot_emit_storm <count> — send ONE coalesced reboot-loop message on each
# routed+capable+enabled channel. Fire-once (no rc-2 retry) — a storm is already
# a degraded state and we must not thrash SMS.
_ae_reboot_emit_storm() {
    local _n="$1"
    qlog_warn "Alert engine: reboot storm (n=$_n) — sending coalesced alert"
    if _ae_channel_enabled sms && alert_route_enabled reboot sms; then
        sms_alert_emit reboot 0 storm "$_n"
    fi
    if _ae_channel_enabled email && alert_route_enabled reboot email; then
        email_alert_emit reboot 0 storm "$_n"
    fi
}

# _ae_clock_sane — 0 iff the wall clock has left the 1970 boot window.
_ae_clock_sane() {
    local _now
    _now=$(date +%s 2>/dev/null)
    case "$_now" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_now" -ge "$_AE_SANE_EPOCH" ]
}

# =============================================================================
# alert_engine_reboot_detect — ONE-SHOT boot_id compare + pending stage
# =============================================================================
# Called once from the poller's main() after alert_engine_init (libs loaded),
# and again from alert_engine_check only while a reboot is held for an unset
# clock (_ae_boot_unresolved). Detection lives here (not in the outage machine) so all reboot state sits in
# one place. A bare procd respawn of the poller sees an unchanged boot_id and
# stages nothing; a real reboot changes boot_id and stages a fresh pending file.
alert_engine_reboot_detect() {
    local _live_id
    local _stored_id
    local _cause
    local _boot_epoch

    _live_id=$(cat "$_AE_BOOT_ID_SRC" 2>/dev/null | tr -d ' \r\n')
    # No boot_id (kernel without the entropy file) → never fabricate a reboot.
    [ -n "$_live_id" ] || return 0

    mkdir -p /etc/qmanager 2>/dev/null
    _stored_id=""
    [ -f "$_AE_BOOT_ID_FILE" ] && _stored_id=$(cat "$_AE_BOOT_ID_FILE" 2>/dev/null | tr -d ' \r\n')

    # First run ever (fresh install / first boot): record the id, do NOT alert.
    if [ -z "$_stored_id" ]; then
        _ae_store_boot_id "$_live_id"
        qlog_info "Alert engine: first boot_id recorded ($_live_id), no reboot alert"
        return 0
    fi

    # Same boot → poller respawn, not a reboot. Keep any unsent pending intact.
    [ "$_stored_id" = "$_live_id" ] && return 0

    # boot_id changed → a real reboot happened. Classify, then commit the new id
    # IMMEDIATELY so a mid-boot procd respawn cannot re-detect the same reboot.
    #
    # _boot_epoch is deliberately WALL-CLOCK (now - uptime): it exists only to be
    # compared against the wall-clock epochs in crash.log, so both sides must use
    # the same clock (crash.log breadcrumbs are wall-clock stamped, so a monotonic
    # clock cannot be used). Until NITZ/ntpd sets the clock it still reads 1970:
    # the in-window breadcrumb would be missed (a planned reboot labelled
    # "unplanned") and the post-facto "unplanned" row would carry a 1970 epoch.
    # So hold: leave the id uncommitted (a respawn in the window re-detects it)
    # and let alert_engine_check retry once the clock is sane.
    if ! _ae_clock_sane; then
        if [ "$_ae_boot_unresolved" != "$_live_id" ]; then
            qlog_info "Alert engine: boot_id changed, clock not set yet, holding reboot classification"
        fi
        _ae_boot_unresolved="$_live_id"
        return 0
    fi
    _ae_boot_unresolved=""
    _boot_epoch=$(( $(date +%s) - $(mono_now) ))
    _cause=$(_ae_classify_reboot "$_boot_epoch")

    # An unplanned boot leaves no breadcrumb of its own — record one now (post
    # facto) so it appears in the "recent reboots" history and counts toward the
    # storm coalescer. record_planned_reboot is a neutral ledger writer; the
    # tier4 token bucket ignores this row (it counts tier4_escalation only).
    if [ "$_cause" = "unplanned" ]; then
        record_planned_reboot "unplanned" 2>/dev/null || true
    fi

    _ae_stage_reboot_pending "$_live_id" "$_cause"
    _ae_store_boot_id "$_live_id"
    qlog_info "Alert engine: reboot detected (cause=$_cause boot_id=$_live_id)"
}

# =============================================================================
# _ae_reboot_check — per-cycle post-recovery delivery of a staged reboot alert
# =============================================================================
_ae_reboot_check() {
    local _cause
    local _mono0
    local _age
    local _storm_n

    # Cheap early-out: nothing staged.
    [ -f "$_AE_REBOOT_PENDING" ] || return 0

    # Deliver only once the internet is actually back (SMS needs registration,
    # email needs DNS). Caller already ruled out null/"".
    [ "$conn_internet_available" = "true" ] || return 0

    # Null-safe reads (project rule: never `//`, even when provably safe).
    _cause=$(jq -r '.cause | if . == null then "unplanned" else . end' "$_AE_REBOOT_PENDING" 2>/dev/null)
    _mono0=$(jq -r '.detected_mono | if . == null then 0 else . end' "$_AE_REBOOT_PENDING" 2>/dev/null)
    case "$_mono0" in ''|*[!0-9]*) _mono0=0 ;; esac

    # Age since detection (monotonic) — approximates "time since back online",
    # which is what the message conveys ("rebooted ~Xm ago").
    _age=$(( $(mono_now) - _mono0 ))
    [ "$_age" -lt 0 ] && _age=0

    # --- Storm coalescer ----------------------------------------------------
    _storm_n=$(_ae_reboot_count_last_hour)
    if [ "$_storm_n" -gt "$_AE_REBOOT_STORM_THRESHOLD" ]; then
        if _ae_storm_flag_fresh; then
            # Already alerted this hour → suppress this boot's per-reboot alert.
            qlog_info "Alert engine: reboot storm already alerted this hour, dropping pending (n=$_storm_n)"
        else
            _ae_reboot_emit_storm "$_storm_n"
            mono_now > "$_AE_REBOOT_STORM_FLAG" 2>/dev/null
        fi
        rm -f "$_AE_REBOOT_PENDING"
        return 0
    fi

    # --- Per-channel delivery (routing AND capability AND master-enable) ----
    # A channel that is not actionable (disabled or not routed for reboot) is
    # trivially "done" — nothing to send. SMS returns rc 2 until the modem
    # re-registers; leave it unmarked and retry next cycle.
    _ae_reboot_deliver_channel sms   "$_age" "$_cause"
    _ae_reboot_deliver_channel email "$_age" "$_cause"

    # Drop the pending file once BOTH channels are done (sent, terminally
    # failed, or not-actionable). A channel still pending an SMS retry keeps the
    # file for the next cycle.
    if _ae_reboot_channel_done sms && _ae_reboot_channel_done email; then
        qlog_info "Alert engine: reboot alert complete (cause=$_cause), clearing pending"
        rm -f "$_AE_REBOOT_PENDING"
    fi
}

# _ae_reboot_deliver_channel <channel> <age> <cause> — attempt one channel.
# No-op (and leaves the channel "done" via not-actionable) when the channel is
# master-disabled or reboot is not routed to it.
_ae_reboot_deliver_channel() {
    local _ch="$1"
    local _age="$2"
    local _cause="$3"
    local _rc

    # Already delivered? (per-channel flag true in the pending file)
    _ae_reboot_channel_done "$_ch" && return 0
    # Not actionable → nothing to attempt; it counts as done for teardown.
    _ae_channel_enabled "$_ch" || return 0
    alert_route_enabled reboot "$_ch" || return 0

    case "$_ch" in
        sms)   sms_alert_emit reboot "$_age" "$_cause" ;;
        email) email_alert_emit reboot "$_age" "$_cause" ;;
        *)     return 0 ;;
    esac
    _rc=$?

    # rc 2 = not ready (SMS modem not yet re-registered) → retry next cycle,
    # leave the flag unset. rc 0 (sent) / rc 1 (terminal fail) → mark done.
    if [ "$_rc" != "2" ]; then
        _ae_reboot_mark_sent "$_ch"
    fi
}

# _ae_reboot_channel_done <channel> — returns 0 if the channel needs no further
# work: either it already delivered (flag true) OR it is not actionable
# (master-disabled or reboot not routed to it, so there is nothing to send).
_ae_reboot_channel_done() {
    local _ch="$1"
    local _flag
    # Null-safe boolean reads — NEVER `//` on a JSON boolean (a stored `false`
    # would be coerced by `//`). Use the explicit if . == null form.
    case "$_ch" in
        sms)   _flag=$(jq -r 'if (.sms_sent   | if . == null then false else . end) then "1" else "0" end' "$_AE_REBOOT_PENDING" 2>/dev/null) ;;
        email) _flag=$(jq -r 'if (.email_sent | if . == null then false else . end) then "1" else "0" end' "$_AE_REBOOT_PENDING" 2>/dev/null) ;;
        *)     return 0 ;;
    esac
    [ "$_flag" = "1" ] && return 0
    # Not yet flagged: done only if it is not actionable (nothing to send).
    if _ae_channel_enabled "$_ch" && alert_route_enabled reboot "$_ch"; then
        return 1
    fi
    return 0
}
