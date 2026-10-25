#!/bin/sh
# =============================================================================
# scenario_mgr.sh — QManager Connection Scenario Manager Library
# =============================================================================
# A sourceable library providing connection scenario resolution, AT-command
# apply (mode_pref + band locks), per-profile schedule resolution, and the
# crontab plumbing that binds a scenario schedule to the active SIM profile.
#
# This is a LIBRARY — no persistent process, no polling.
# CGI scripts (scenarios/activate.sh), the cron worker
# (qmanager_scenario_schedule), and the profile apply worker source it.
#
# Dependencies: qcmd, qlog_* functions (from qlog.sh), jq, crontab
# Install location: /usr/lib/qmanager/scenario_mgr.sh
#
# Usage:
#   . /usr/lib/qmanager/scenario_mgr.sh
#   scenario_resolve_config <id>          → "<MODE> <LTE> <NSA> <SA>" or rc 1
#   scenario_apply <id>                   → send AT; rc 0 ok / 2 partial / 1 fail
#   scenario_is_known <id>                → rc 0 if a valid/known scenario id
#   scenario_profile_block <profile_id>   → normalized .scenario object (jq -c)
#   scenario_profile_schedule_enabled <p> → "true"/"false"
#   scenario_block_for_now <profile_id>   → scenario id active right now
#   scenario_install_cron <profile_id>    → install marked cron + snap-to-now
#   scenario_teardown_cron                → remove marked cron lines
#
# NETWORK MODE + BANDS are owned by Connection Scenarios (not SIM Profiles).
# scenario_apply NEVER reboots — it issues mode_pref + band locks only.
# =============================================================================

[ -n "$_SCENARIO_MGR_LOADED" ] && return 0
_SCENARIO_MGR_LOADED=1

[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

# --- Configuration -----------------------------------------------------------
SCENARIOS_DIR="/etc/qmanager/scenarios"
ACTIVE_SCENARIO_FILE="/etc/qmanager/active_scenario"
PROFILE_DIR="/etc/qmanager/profiles"
SCENARIO_CRON_MARKER="qmanager_profile_scenario"
SCENARIO_SCHEDULE_SCRIPT="/usr/bin/qmanager_scenario_schedule"

# Read-time migration default for profiles with no .scenario object.
SCENARIO_DEFAULT_BLOCK='{"default":"balanced","schedule":{"enabled":false,"blocks":[]}}'

mkdir -p /etc/qmanager 2>/dev/null

# =============================================================================
# Scenario Config Resolution
# =============================================================================

# scenario_is_known <id>
# Returns 0 if the id is a built-in default or an existing custom-*.json file.
scenario_is_known() {
    local id="$1"
    case "$id" in
        balanced|gaming|streaming) return 0 ;;
        custom-[0-9]*) [ -f "$SCENARIOS_DIR/${id}.json" ] && return 0; return 1 ;;
        *) return 1 ;;
    esac
}

# scenario_resolve_config <id>
# DISK is the single source of truth for custom-scenario config (D1).
# Echoes 4 space-joined fields: "<AT_MODE> <LTE_BANDS> <NSA_NR_BANDS> <SA_NR_BANDS>"
# Empty band fields are emitted as the "-" sentinel so positional splitting holds.
# Built-in defaults send mode only (bands left unchanged) — matches the historic
# activate.sh behavior. Returns 1 on unknown id / unreadable custom file.
scenario_resolve_config() {
    local id="$1"
    local mode=""
    local lte=""
    local nsa=""
    local sa=""

    case "$id" in
        balanced)  mode="AUTO" ;;
        gaming)    mode="NR5G" ;;
        streaming) mode="LTE:NR5G" ;;
        custom-[0-9]*)
            local f="$SCENARIOS_DIR/${id}.json"
            [ -f "$f" ] || return 1
            mode=$(jq -r '(.config.atModeValue) | if . == null then empty else tostring end' "$f" 2>/dev/null)
            lte=$(jq -r '(.config.lte_bands) | if . == null then empty else tostring end' "$f" 2>/dev/null)
            nsa=$(jq -r '(.config.nsa_nr_bands) | if . == null then empty else tostring end' "$f" 2>/dev/null)
            sa=$(jq -r '(.config.sa_nr_bands) | if . == null then empty else tostring end' "$f" 2>/dev/null)
            [ -n "$mode" ] || return 1
            ;;
        *) return 1 ;;
    esac

    case "$mode" in
        AUTO|LTE|NR5G|LTE:NR5G) ;;
        *) return 1 ;;
    esac

    printf '%s %s %s %s' "$mode" "${lte:--}" "${nsa:--}" "${sa:--}"
    return 0
}

# _scenario_send_at <cmd> <label>
# Sends one AT command via qcmd, treats empty/ERROR as failure. Returns 0/1.
_scenario_send_at() {
    local cmd="$1"
    local label="$2"

    local result
    result=$(qcmd "$cmd" 2>/dev/null)
    local rc=$?

    if [ "$rc" -ne 0 ] || [ -z "$result" ]; then
        qlog_error "$label: AT command failed (rc=$rc): $cmd" 2>/dev/null
        return 1
    fi

    case "$result" in
        *ERROR*)
            qlog_error "$label: AT returned ERROR: $cmd -> $result" 2>/dev/null
            return 1
            ;;
    esac

    qlog_info "$label: OK" 2>/dev/null
    return 0
}

# scenario_apply <id>
# Resolves config from disk, sends mode_pref then any non-empty band locks.
# NEVER reboots. Persists the active scenario marker on apply.
# Returns: 0 = full success, 2 = mode ok but a band lock failed (partial),
#          1 = unknown id or mode_pref failed (no marker written).
scenario_apply() {
    local id="$1"

    local cfg
    cfg=$(scenario_resolve_config "$id") || {
        qlog_error "scenario_apply: cannot resolve scenario '$id'" 2>/dev/null
        return 1
    }

    local mode
    local lte
    local nsa
    local sa
    mode=$(printf '%s' "$cfg" | cut -d' ' -f1)
    lte=$(printf '%s' "$cfg" | cut -d' ' -f2)
    nsa=$(printf '%s' "$cfg" | cut -d' ' -f3)
    sa=$(printf '%s' "$cfg" | cut -d' ' -f4)
    [ "$lte" = "-" ] && lte=""
    [ "$nsa" = "-" ] && nsa=""
    [ "$sa" = "-" ] && sa=""

    qlog_info "Applying scenario: $id (mode=$mode, lte=$lte, nsa=$nsa, sa=$sa)" 2>/dev/null

    if ! _scenario_send_at "AT+QNWPREFCFG=\"mode_pref\",${mode}" "mode_pref"; then
        return 1
    fi

    local failed=0
    if [ -n "$lte" ]; then
        sleep 0.2
        _scenario_send_at "AT+QNWPREFCFG=\"lte_band\",${lte}" "lte_band" || failed=1
    fi
    if [ -n "$nsa" ]; then
        sleep 0.2
        _scenario_send_at "AT+QNWPREFCFG=\"nsa_nr5g_band\",${nsa}" "nsa_nr5g_band" || failed=1
    fi
    if [ -n "$sa" ]; then
        sleep 0.2
        _scenario_send_at "AT+QNWPREFCFG=\"nr5g_band\",${sa}" "nr5g_band" || failed=1
    fi

    mkdir -p "$(dirname "$ACTIVE_SCENARIO_FILE")" 2>/dev/null
    if command -v qm_durable_write >/dev/null 2>&1; then
        printf '%s' "$id" | qm_durable_write "$ACTIVE_SCENARIO_FILE" || failed=1
    else
        printf '%s' "$id" > "$ACTIVE_SCENARIO_FILE"
    fi

    [ "$failed" -eq 1 ] && return 2
    return 0
}

# scenario_reset_to_default
# Reset the radio + active_scenario marker to the canonical default (Balanced).
# MODE-ONLY: scenario_apply "balanced" issues AT+QNWPREFCFG="mode_pref",AUTO and
# writes the active_scenario marker. Band locks a prior custom scenario applied
# are intentionally NOT cleared (built-in Balanced is mode-only by design).
# This is the deactivate-time inverse of scenario_install_cron. Never reboots.
scenario_reset_to_default() {
    scenario_apply "balanced"
}

# =============================================================================
# Per-Profile Scenario Block Readers (read-time migration defaults)
# =============================================================================

# scenario_profile_block <profile_id>
# Echoes the normalized .scenario object (jq -c). Legacy profiles with no
# .scenario object return the default block. Always emits default+schedule keys.
scenario_profile_block() {
    local pf="$PROFILE_DIR/${1}.json"
    if [ ! -f "$pf" ]; then
        printf '%s' "$SCENARIO_DEFAULT_BLOCK"
        return 0
    fi
    jq -c '
        (.scenario // {}) as $s
        | {
            default: ($s.default // "balanced"),
            schedule: {
                enabled: ($s.schedule.enabled // false),
                blocks: ($s.schedule.blocks // [])
            }
          }' "$pf" 2>/dev/null || printf '%s' "$SCENARIO_DEFAULT_BLOCK"
}

# scenario_profile_schedule_enabled <profile_id>
# Echoes "true" or "false".
scenario_profile_schedule_enabled() {
    scenario_profile_block "$1" | jq -r '.schedule.enabled | tostring' 2>/dev/null
}

# =============================================================================
# Snap-to-Now Resolution (CANONICAL — a TS port must mirror this exactly)
# =============================================================================
# Semantics (D6): start inclusive, end exclusive. When end <= start the block
# wraps past midnight. First matching block in array order wins ($hits[0]).
# Falls back to .default when schedule disabled or no block covers now.
# All minute arithmetic happens inside jq (tonumber on "08"/"09" is clean) —
# never in shell $(()), which mishandles octal-leading-zero "08"/"09".

# scenario_block_for_now <profile_id>
scenario_block_for_now() {
    local block
    block=$(scenario_profile_block "$1")

    local now_dow
    local now_h
    local now_m
    now_dow=$(date +%w)   # 0=Sun .. 6=Sat
    now_h=$(date +%H)
    now_m=$(date +%M)

    printf '%s' "$block" | jq -r \
        --argjson dow "$now_dow" \
        --arg hh "$now_h" \
        --arg mm "$now_m" '
        (($hh | tonumber) * 60 + ($mm | tonumber)) as $m
        | (.default) as $dflt
        | ( .schedule
            | if (.enabled | not) then $dflt
              else
                ( [ .blocks[]
                    | (.start | split(":") | (.[0] | tonumber) * 60 + (.[1] | tonumber)) as $s
                    | (.end   | split(":") | (.[0] | tonumber) * 60 + (.[1] | tonumber)) as $e
                    | select(.days | index($dow) != null)
                    | select( if $e > $s then ($m >= $s and $m < $e)
                              else ($m >= $s or $m < $e) end )
                    | .scenario
                  ] ) as $hits
                | ($hits[0] // $dflt)
              end )
        ' 2>/dev/null
}

# =============================================================================
# Cron Install / Teardown
# =============================================================================
# Single root crontab shared with qmanager_tower_schedule / _scheduled_reboot.
# Our marker (qmanager_profile_scenario) shares no substring with those, so `grep -v "$SCENARIO_CRON_MARKER"` only touches our lines.
#
# crond "active with no instances" trap: procd only spawns crond once a
# non-empty crontab exists; writing via `crontab -` starts it. Teardown to an
# empty crontab mirrors tower/schedule.sh: `echo "" | crontab -`.

# _scenario_crontab_without_marker
# Echoes the current crontab with our marked lines removed.
# The header comment is also stripped so scenario_install_cron's single
# re-prepend leaves exactly one copy — collapsing any pre-existing duplicates.
_scenario_crontab_without_marker() {
    crontab -l 2>/dev/null \
        | grep -v "$SCENARIO_CRON_MARKER" \
        | grep -v "^# QManager Profile Scenario Schedule"
}

# scenario_teardown_cron
# Removes only our marked lines. Safe to call unconditionally. If nothing else
# remains, installs an empty crontab so crond doesn't run a stale view.
scenario_teardown_cron() {
    local cleaned
    cleaned=$(_scenario_crontab_without_marker)
    if [ -n "$cleaned" ]; then
        printf '%s\n' "$cleaned" | crontab -
    else
        echo "" | crontab -
    fi
    qlog_info "Scenario schedule cron lines removed" 2>/dev/null
}

# _scenario_generate_cron_lines <profile_id>
# Emits the de-duplicated transition cron lines for the profile's schedule.
# One line per real change point, grouped across weekdays that share the same
# (minute, scenario). All timeline math runs in jq. Output lines are bare cron
# entries WITHOUT the trailing marker comment — the caller appends it so the
# marker text lives in exactly one place.
#
# Algorithm (see scenario-profile-binding feature doc):
#   1. For each weekday 0..6, gather block start->scenario and end->default
#      transitions. Overnight (end<=start): the default-restore lands on the
#      NEXT weekday.
#   2. Within a weekday, sort by minute; at equal minutes a block-start (rank 1)
#      orders AFTER a default-restore (rank 0) so a start overrides a touching
#      block end — no flap at shared boundaries.
#   3. Walk per weekday tracking the running scenario (seed = default); emit a
#      transition only when the target differs from the running scenario.
#   4. Group surviving (minute, scenario) across weekdays into one line with a
#      comma day-list.
#   5. Render: "<min> <hour> * * <days> <SCRIPT> <scenario>"
_scenario_generate_cron_lines() {
    local block
    block=$(scenario_profile_block "$1")

    printf '%s' "$block" | jq -r \
        --arg script "$SCENARIO_SCHEDULE_SCRIPT" '
        (.default) as $dflt
        | (.schedule.blocks) as $blocks
        # eff($dow; $m): effective scenario at a weekday+minute using the same
        # first-match snap logic as scenario_block_for_now. Used to seed each
        # weekday with the scenario in effect at the end of the PREVIOUS day,
        # so an overnight block bleeding into the next day still emits its
        # restore transition (the per-day reduce would otherwise drop it).
        | def eff($dow; $m):
            ( [ $blocks[]
                | (.start | split(":") | (.[0]|tonumber)*60 + (.[1]|tonumber)) as $s
                | (.end   | split(":") | (.[0]|tonumber)*60 + (.[1]|tonumber)) as $e
                | select(.days | index($dow) != null)
                | select( if $e > $s then ($m >= $s and $m < $e)
                          else ($m >= $s or $m < $e) end )
                | .scenario ] | (.[0] // $dflt) );
        # Build raw transitions tagged by weekday. rank: 0=restore, 1=start.
        [ range(0;7) as $d
            | ( $blocks[]
                | (.start | split(":") | (.[0]|tonumber)*60 + (.[1]|tonumber)) as $s
                | (.end   | split(":") | (.[0]|tonumber)*60 + (.[1]|tonumber)) as $e
                | select(.days | index($d) != null)
                | (
                    # start transition on day $d
                    {day:$d, min:$s, rank:1, scen:(.scenario)},
                    # end (default-restore): same day if normal, next day if wrap
                    (if $e > $s
                       then {day:$d,            min:$e, rank:0, scen:$dflt}
                       else {day:(($d+1)%7),    min:$e, rank:0, scen:$dflt}
                     end)
                  )
              )
          ]
        # Group by weekday, then resolve to real change points.
        | [ range(0;7) as $d
            # First collapse all transitions at the SAME minute to the single
            # highest-rank winner (a block-start, rank 1, overrides a touching
            # block default-restore, rank 0, at a shared boundary). Sorting
            # ascending and taking the last per minute yields that winner.
            | ( [ .[] | select(.day == $d) ]
                | sort_by([.min, .rank])
                | group_by(.min)
                | map(.[-1])
                | sort_by(.min) ) as $day
            # Seed the running scenario with the effective scenario at 23:59 of
            # the previous weekday (handles overnight blocks crossing midnight).
            | ( eff((($d + 6) % 7); 1439) ) as $seed
            # Then emit a transition only when the effective scenario actually
            # changes from the running value.
            | ( reduce $day[] as $t
                  ( {run:$seed, out:[]};
                    if $t.scen == .run then .
                    else { run:$t.scen, out:(.out + [{day:$d, min:$t.min, scen:$t.scen}]) }
                    end )
              ) .out[]
          ]
        # Group across weekdays by identical (min, scen) → comma day-list.
        | group_by([.min, .scen])[]
        | (.[0].min) as $min
        | (.[0].scen) as $scen
        | ([ .[].day ] | sort | map(tostring) | join(",")) as $days
        | "\($min % 60) \(($min - ($min % 60))/60) * * \($days) \($script) \($scen)"
        ' 2>/dev/null
}

# scenario_install_cron <profile_id>
# Installs the marked cron lines for the profile (only when schedule.enabled),
# then snaps the modem to whatever scenario covers "now". When schedule is
# disabled, tears down any leftover lines and applies the on-activate default.
scenario_install_cron() {
    local pid="$1"

    local enabled
    enabled=$(scenario_profile_schedule_enabled "$pid")

    if [ "$enabled" != "true" ]; then
        # No schedule: ensure no stale lines, then apply the on-activate default.
        scenario_teardown_cron
        local def
        def=$(scenario_profile_block "$pid" | jq -r '.default // "balanced"' 2>/dev/null)
        [ -z "$def" ] && def="balanced"
        scenario_is_known "$def" || def="balanced"
        scenario_apply "$def"
        qlog_info "Scenario schedule disabled for $pid — applied default '$def'" 2>/dev/null
        return 0
    fi

    local lines
    lines=$(_scenario_generate_cron_lines "$pid")

    local cleaned
    cleaned=$(_scenario_crontab_without_marker)

    if [ -n "$lines" ]; then
        # Append marker to each generated line, then merge with the cleaned
        # crontab. printf the marker comment exactly once per line here.
        local marked
        marked=$(printf '%s\n' "$lines" | sed "s|\$|  # ${SCENARIO_CRON_MARKER}|")
        printf '%s\n# QManager Profile Scenario Schedule — DO NOT EDIT MANUALLY\n%s\n' \
            "$cleaned" "$marked" | crontab -
        # BusyBox crond stays dormant ("active with no instances") after the
        # first crontab write — `crontab -` alone does not poke it, so on a
        # clean device the schedule would never fire. Reload to spawn/refresh
        # crond. Backgrounded to keep the CGI response prompt (matches the
        # system/settings.sh TZ-change idiom). Teardown does NOT need this — a
        # running crond rescans every minute.
        ( /etc/init.d/cron reload </dev/null >/dev/null 2>&1 & )
        qlog_info "Scenario schedule cron installed for $pid" 2>/dev/null
    else
        # Schedule enabled but produced no transitions (e.g. empty blocks).
        scenario_teardown_cron
        qlog_warn "Scenario schedule enabled for $pid but no cron transitions generated" 2>/dev/null
    fi

    # Snap to now (D6) regardless of whether lines were generated.
    local now_id
    now_id=$(scenario_block_for_now "$pid")
    [ -z "$now_id" ] && now_id="balanced"
    scenario_is_known "$now_id" || now_id="balanced"
    scenario_apply "$now_id"
    qlog_info "Scenario snap-to-now for $pid → '$now_id'" 2>/dev/null
    return 0
}
