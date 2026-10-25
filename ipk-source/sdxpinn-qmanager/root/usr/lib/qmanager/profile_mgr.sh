#!/bin/sh
# =============================================================================
# profile_mgr.sh — QManager SIM Profile Manager Library
# =============================================================================
# A sourceable library providing profile CRUD operations, validation,
# AT command conversion helpers, and active profile management.
#
# This is a LIBRARY — no persistent process, no polling.
# CGI scripts and the apply script source it and call functions directly.
#
# Dependencies: qlog_* functions (from qlog.sh)
# Install location: /usr/lib/qmanager/profile_mgr.sh
#
# Usage:
#   . /usr/lib/qmanager/profile_mgr.sh
#   profile_list        → JSON array of profile summaries
#   profile_get <id>    → Full profile JSON
#   profile_save        → Create/update profile (reads JSON from stdin)
#   profile_delete <id> → Remove profile + cleanup
#   profile_count       → Current number of profiles
#   get_active_profile  → Read active profile ID
#   set_active_profile <id> → Write active profile ID
#   clear_active_profile    → Clear active profile
# =============================================================================

[ -n "$_PROFILE_MGR_LOADED" ] && return 0
_PROFILE_MGR_LOADED=1

# Known-SIMs / ICCID helpers. Sourced at top (idempotent via _SIM_DB_LOADED) so
# iccid_canonicalize is always defined for auto_apply_profile's compare logic.
if [ -f /usr/lib/qmanager/sim_db.sh ]; then
    . /usr/lib/qmanager/sim_db.sh
else
    # Mirrors sim_db.sh's canonicalizer so ICCID compares stay consistent.
    iccid_canonicalize() {
        local _simdb_canon
        _simdb_canon=$(printf '%s' "$1" | tr -d ' \r\n')
        case "$_simdb_canon" in
            *[Ff]) _simdb_canon=${_simdb_canon%?} ;;
        esac
        printf '%s' "$_simdb_canon"
    }
    sim_db_add() { :; }
fi

# qm_durable_write for the active marker (crash-safe on UBIFS).
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

# --- Configuration -----------------------------------------------------------
PROFILE_DIR="/etc/qmanager/profiles"
ACTIVE_PROFILE_FILE="/etc/qmanager/active_profile"
PROFILE_APPLY_PID_FILE="/tmp/qmanager_profile_apply.pid"
PROFILE_SPAWN_LOCK_FILE="/tmp/qmanager_profile_spawn.lock"
# Written when auto_apply_profile finds a worker already running; the worker
# consumes it on exit and re-runs auto_apply for the freshest SIM (latest wins).
PROFILE_PENDING_APPLY_FILE="/tmp/qmanager_profile_pending_apply"
MAX_PROFILES=10

# Ensure profile directory exists
mkdir -p "$PROFILE_DIR" 2>/dev/null

# --- Profile ID Generation ---------------------------------------------------
# Format: p_<unix_timestamp>_<3-char-hex>
# Uses /dev/urandom with hexdump (BusyBox-safe).
_generate_profile_id() {
    local ts
    local suffix
    ts=$(date +%s)
    suffix=$(hexdump -n 2 -e '"%04x"' /dev/urandom 2>/dev/null | cut -c1-3)
    # Fallback if hexdump fails
    [ -z "$suffix" ] && suffix=$(printf '%03x' $$)
    echo "p_${ts}_${suffix}"
}

# --- Validation Helpers -------------------------------------------------------

# Validate IMEI: exactly 15 digits
_validate_imei() {
    case "$1" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;;
        '') return 0 ;; # Empty IMEI allowed (means "don't change")
        *) return 1 ;;
    esac
}

# Validate TTL/HL: integer 0-255
_validate_ttl_hl() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *)
            [ "$1" -ge 0 ] && [ "$1" -le 255 ] 2>/dev/null && return 0
            return 1
            ;;
    esac
}

# Validate PDP type
_validate_pdp_type() {
    case "$1" in
        IP|IPV6|IPV4V6) return 0 ;;
        *) return 1 ;;
    esac
}

# Validate CID: 1-15
_validate_cid() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *)
            [ "$1" -ge 1 ] && [ "$1" -le 15 ] 2>/dev/null && return 0
            return 1
            ;;
    esac
}

# =============================================================================
# Profile CRUD Operations
# =============================================================================

# --- profile_count -----------------------------------------------------------
# Returns the number of profile files in the profiles directory.
profile_count() {
    local count=0
    for f in "$PROFILE_DIR"/p_*.json; do
        [ -f "$f" ] && count=$((count + 1))
    done
    echo "$count"
}

# --- profile_list ------------------------------------------------------------
# Returns a JSON object with a profiles array (summaries) and active_profile_id.
# Output: {"profiles":[...],"active_profile_id":"..."}
profile_list() {
    local active_id
    local profiles_json
    active_id=$(get_active_profile)

    # Collect matching profile files
    local files=""
    for f in "$PROFILE_DIR"/p_*.json; do
        [ -f "$f" ] && files="$files $f"
    done

    # Build profiles array: extract summary fields from each file
    if [ -n "$files" ]; then
        profiles_json=$(jq -s '[.[] | {
            id, name, mno, sim_iccid, created_at, updated_at,
            scenario: (
                (.scenario // {}) as $s
                | {
                    default: ($s.default // "balanced"),
                    schedule: {
                        enabled: ($s.schedule.enabled // false),
                        blocks: ($s.schedule.blocks // [])
                    }
                  }
            )
        }]' $files 2>/dev/null)
        [ -z "$profiles_json" ] && profiles_json="[]"
    else
        profiles_json="[]"
    fi

    # Build final response
    if [ -n "$active_id" ]; then
        jq -n --argjson profiles "$profiles_json" --arg active "$active_id" \
            '{profiles: $profiles, active_profile_id: $active}'
    else
        jq -n --argjson profiles "$profiles_json" \
            '{profiles: $profiles, active_profile_id: null}'
    fi
}

# --- profile_get <id> --------------------------------------------------------
# Returns the full profile JSON for a given ID.
# Applies the read-time scenario default so legacy profiles (saved before the
# scenario-binding feature) always expose a normalized .scenario block to the
# editor. Falls back to raw cat if jq fails (never lose the profile data).
# Returns 1 if profile not found.
profile_get() {
    local id="$1"
    local file="$PROFILE_DIR/${id}.json"

    if [ ! -f "$file" ]; then
        qlog_warn "Profile not found: $id" 2>/dev/null
        return 1
    fi

    jq '
        .scenario = (
            (.scenario // {}) as $s
            | {
                default: ($s.default // "balanced"),
                schedule: {
                    enabled: ($s.schedule.enabled // false),
                    blocks: ($s.schedule.blocks // [])
                }
              }
        )' "$file" 2>/dev/null || cat "$file"
}

# --- profile_save ------------------------------------------------------------
# Creates or updates a profile. Reads JSON from stdin.
# On create: generates ID, sets created_at/updated_at, enforces 10-limit.
# On update: preserves ID + created_at, updates updated_at.
# Output: {"success":true,"id":"<profile_id>"} on stdout.
# Returns 1 on validation failure (error JSON on stdout).
profile_save() {
    local input
    input=$(cat)

    if [ -z "$input" ]; then
        printf '{"success":false,"error":"empty_input","detail":"No profile data provided"}\n'
        return 1
    fi

    # --- Extract all fields from input JSON ---
    local name
    local mno
    local sim_iccid
    local apn_cid
    local apn_name
    local apn_pdp_type
    local imei
    local ttl
    local hl
    local existing_id

    name=$(printf '%s' "$input" | jq -r '(.name) | if . == null then empty else tostring end')
    mno=$(printf '%s' "$input" | jq -r '(.mno) | if . == null then empty else tostring end')
    sim_iccid=$(printf '%s' "$input" | jq -r '(.sim_iccid) | if . == null then empty else tostring end')
    existing_id=$(printf '%s' "$input" | jq -r '(.id) | if . == null then empty else tostring end')

    # APN settings — frontend sends these as flat keys
    apn_cid=$(printf '%s' "$input" | jq -r '(.cid) | if . == null then empty else tostring end')
    apn_name=$(printf '%s' "$input" | jq -r '(.apn_name) | if . == null then empty else tostring end')
    apn_pdp_type=$(printf '%s' "$input" | jq -r '(.pdp_type) | if . == null then empty else tostring end')

    imei=$(printf '%s' "$input" | jq -r '(.imei) | if . == null then empty else tostring end')
    ttl=$(printf '%s' "$input" | jq -r '(.ttl) | if . == null then empty else tostring end')
    hl=$(printf '%s' "$input" | jq -r '(.hl) | if . == null then empty else tostring end')

    # Scenario binding block. Normalize to {default, schedule:{enabled, blocks}}
    # with read-time defaults so callers omitting it still produce a valid
    # object. Must be threaded through the fixed jq output template below or it
    # is silently dropped on save.
    local scenario_in
    scenario_in=$(printf '%s' "$input" | jq -c '
        (.scenario // {}) as $s
        | {
            default: ($s.default // "balanced"),
            schedule: {
                enabled: ($s.schedule.enabled // false),
                blocks: ($s.schedule.blocks // [])
            }
          }' 2>/dev/null)
    [ -z "$scenario_in" ] && scenario_in='{"default":"balanced","schedule":{"enabled":false,"blocks":[]}}'

    # --- Apply defaults for optional fields ---
    [ -z "$apn_cid" ] && apn_cid=1
    [ -z "$apn_pdp_type" ] && apn_pdp_type="IPV4V6"
    [ -z "$ttl" ] && ttl=0
    [ -z "$hl" ] && hl=0

    # --- Validation ---
    local errors=""

    if [ -z "$name" ]; then
        errors="${errors}Profile name is required. "
    fi

    if ! _validate_cid "$apn_cid"; then
        errors="${errors}CID must be 1-15. "
    fi

    if [ -n "$apn_pdp_type" ] && ! _validate_pdp_type "$apn_pdp_type"; then
        errors="${errors}Invalid PDP type (must be IP, IPV6, or IPV4V6). "
    fi

    if [ -n "$imei" ] && ! _validate_imei "$imei"; then
        errors="${errors}IMEI must be exactly 15 digits. "
    fi

    if ! _validate_ttl_hl "$ttl"; then
        errors="${errors}TTL must be 0-255. "
    fi

    if ! _validate_ttl_hl "$hl"; then
        errors="${errors}HL must be 0-255. "
    fi

    # Reject unknown scenario references (Risk #10). Both .default and every
    # block .scenario must resolve to a known scenario (balanced|gaming|
    # streaming|an existing custom-*.json). scenario_is_known lives in
    # scenario_mgr.sh — lazy-source it (profile_mgr.sh callers may not have it).
    if ! command -v scenario_is_known >/dev/null 2>&1; then
        if [ -f /usr/lib/qmanager/scenario_mgr.sh ]; then
            . /usr/lib/qmanager/scenario_mgr.sh
        fi
    fi
    if command -v scenario_is_known >/dev/null 2>&1; then
        local _scn_ref
        local _scn_bad
        _scn_bad=""
        for _scn_ref in $(printf '%s' "$scenario_in" | jq -r '[.default] + [.schedule.blocks[].scenario] | .[]' 2>/dev/null); do
            scenario_is_known "$_scn_ref" || _scn_bad="$_scn_ref"
        done
        if [ -n "$_scn_bad" ]; then
            errors="${errors}Unknown connection scenario: ${_scn_bad}. "
        fi
    fi

    if [ -n "$errors" ]; then
        jq -n --arg detail "$errors" \
            '{success: false, error: "validation_failed", detail: $detail}'
        return 1
    fi

    # --- Determine if create or update ---
    local id
    local created_at
    local updated_at
    updated_at=$(date +%s)

    if [ -n "$existing_id" ] && [ -f "$PROFILE_DIR/${existing_id}.json" ]; then
        # UPDATE: preserve ID and created_at
        id="$existing_id"
        created_at=$(jq -r '(.created_at) | if . == null then empty else tostring end' "$PROFILE_DIR/${id}.json" 2>/dev/null)
        [ -z "$created_at" ] && created_at="$updated_at"
        qlog_info "Updating profile: $id ($name)" 2>/dev/null
    else
        # CREATE: enforce limit, generate ID
        local count
        count=$(profile_count)
        if [ "$count" -ge "$MAX_PROFILES" ]; then
            jq -n --argjson max "$MAX_PROFILES" \
                '{"success":false,"error":"limit_reached","detail":("Maximum " + ($max | tostring) + " profiles allowed")}'
            return 1
        fi
        id=$(_generate_profile_id)
        created_at="$updated_at"
        qlog_info "Creating profile: $id ($name)" 2>/dev/null
    fi

    # --- Write profile JSON to temp file, then atomic mv ---
    local tmp_file="$PROFILE_DIR/${id}.json.tmp"
    local final_file="$PROFILE_DIR/${id}.json"

    jq -n \
        --arg id "$id" \
        --arg name "$name" \
        --arg mno "$mno" \
        --arg sim_iccid "$sim_iccid" \
        --argjson created_at "$created_at" \
        --argjson updated_at "$updated_at" \
        --argjson apn_cid "$apn_cid" \
        --arg apn_name "$apn_name" \
        --arg apn_pdp_type "$apn_pdp_type" \
        --arg imei "$imei" \
        --argjson ttl "$ttl" \
        --argjson hl "$hl" \
        --argjson scenario "$scenario_in" \
        '{
            id: $id,
            name: $name,
            mno: $mno,
            sim_iccid: $sim_iccid,
            created_at: $created_at,
            updated_at: $updated_at,
            settings: {
                apn: {
                    cid: $apn_cid,
                    name: $apn_name,
                    pdp_type: $apn_pdp_type
                },
                imei: $imei,
                ttl: $ttl,
                hl: $hl
            },
            scenario: $scenario
        }' > "$tmp_file" || {
        qlog_error "jq failed writing profile: $id" 2>/dev/null
        rm -f "$tmp_file"
        printf '{"success":false,"error":"write_failed","detail":"Failed to generate profile JSON"}\n'
        return 1
    }

    # Atomic replace. sync before mv so the rename never lands on flash ahead
    # of the data (a power cut would leave a 0-byte profile), and after it.
    sync
    if ! mv "$tmp_file" "$final_file"; then
        qlog_error "Failed to write profile: $id" 2>/dev/null
        rm -f "$tmp_file"
        printf '{"success":false,"error":"write_failed","detail":"Failed to save profile to disk"}\n'
        return 1
    fi
    sync

    jq -n --arg id "$id" '{success: true, id: $id}'
    return 0
}

# --- profile_delete <id> -----------------------------------------------------
# Removes a profile file. Clears active_profile if it was the deleted one.
# Returns 1 if profile not found.
profile_delete() {
    local id="$1"

    if [ -z "$id" ]; then
        printf '{"success":false,"error":"no_id","detail":"Profile ID is required"}\n'
        return 1
    fi

    local file="$PROFILE_DIR/${id}.json"

    if [ ! -f "$file" ]; then
        printf '{"success":false,"error":"not_found","detail":"Profile not found"}\n'
        return 1
    fi

    # Capture the active id BEFORE removing the file: get_active_profile
    # validates by file existence, so after rm -f it would return empty and the
    # teardown branch below would never fire (orphaned scenario cron lines).
    local active_id
    active_id=$(get_active_profile)

    # Remove the file
    if ! rm -f "$file"; then
        qlog_error "Failed to delete profile: $id" 2>/dev/null
        printf '{"success":false,"error":"delete_failed","detail":"Failed to remove profile file"}\n'
        return 1
    fi

    # If this was the active profile, clear it + tear down scenario cron
    if [ "$active_id" = "$id" ]; then
        clear_active_profile
        _profile_teardown_scenario_cron
        _profile_reset_scenario_to_default
        qlog_info "Cleared active profile (deleted: $id)" 2>/dev/null
    fi

    qlog_info "Deleted profile: $id" 2>/dev/null
    jq -n --arg id "$id" '{success: true, id: $id}'
    return 0
}

# =============================================================================
# Active Profile Management
# =============================================================================

# Returns the currently active profile ID, or empty string if none.
get_active_profile() {
    if [ -f "$ACTIVE_PROFILE_FILE" ]; then
        local id
        id=$(cat "$ACTIVE_PROFILE_FILE" 2>/dev/null | tr -d ' \n\r')
        # Verify the profile still exists
        if [ -n "$id" ] && [ -f "$PROFILE_DIR/${id}.json" ]; then
            echo "$id"
        fi
    fi
}

# Set the active profile ID.
set_active_profile() {
    local id="$1"
    if [ -z "$id" ]; then
        return 1
    fi
    # Verify profile exists
    if [ ! -f "$PROFILE_DIR/${id}.json" ]; then
        qlog_warn "Cannot set active profile — not found: $id" 2>/dev/null
        return 1
    fi
    # Durable replace: qmanager_profile_apply calls this right before
    # AT+CFUN=1,1, which can reset the host before writeback.
    if ! command -v qm_durable_write >/dev/null 2>&1 \
            || ! printf '%s' "$id" | qm_durable_write "$ACTIVE_PROFILE_FILE"; then
        qlog_error "Failed to write active profile marker: $id" 2>/dev/null
        return 1
    fi
    qlog_info "Active profile set: $id" 2>/dev/null
    # Explicit success — do not let the function's exit status leak from
    # qlog_info (which can be non-zero under log-level filtering); callers use
    # `set_active_profile ... || return 1`.
    return 0
}

# Clear the active profile.
clear_active_profile() {
    rm -f "$ACTIVE_PROFILE_FILE"
}

# Acknowledge the current SIM as "seen" by adding its ICCID to the known-SIMs
# set (the same set qmanager_poller's boot-time SIM-swap detector consults).
# Called whenever a profile is successfully activated, so activating a profile
# for a freshly-inserted SIM does not leave the SIM unknown and false-fire the
# "New SIM detected" banner on the next reboot. Reads the ICCID with the SAME
# parse pipeline as qmanager_poller (line ~414) so the stored value byte-matches
# what the poller will read at next boot. Skips on empty read — never clobbers.
mark_sim_acknowledged() {
    # Top-of-file source already defined sim_db_add (real or stub); without
    # the library there is no known-SIMs set to write, so skip.
    [ -f /usr/lib/qmanager/sim_db.sh ] || return 0
    . /usr/lib/qmanager/sim_db.sh
    local _acked_iccid
    _acked_iccid=$(qcmd 'AT+QCCID' 2>/dev/null | grep '+QCCID:' | sed 's/+QCCID: //g' | tr -d '\r ')
    if [ -n "$_acked_iccid" ]; then
        sim_db_add "$_acked_iccid"
        qlog_info "Acknowledged current SIM in known set: ...$(printf '%s' "$_acked_iccid" | tail -c 4)" 2>/dev/null
    fi
}

# _profile_teardown_scenario_cron
# Lazy-source scenario_mgr.sh and remove the profile-scenario cron lines.
# Called at every active-profile clear site (deactivate, SIM mismatch, delete
# of active, worker failure) so a scheduled profile leaves no orphaned cron.
# The cron worker's self-heal guard is the backstop, not the primary teardown.
_profile_teardown_scenario_cron() {
    if ! command -v scenario_teardown_cron >/dev/null 2>&1; then
        if [ -f /usr/lib/qmanager/scenario_mgr.sh ]; then
            . /usr/lib/qmanager/scenario_mgr.sh
        fi
    fi
    command -v scenario_teardown_cron >/dev/null 2>&1 && scenario_teardown_cron
    return 0
}

# _profile_reset_scenario_to_default
# Lazy-source scenario_mgr.sh and reset the radio + active_scenario marker to
# Balanced (mode-only: AUTO). Called at every active-profile clear site so a
# deactivated profile's custom scenario no longer keeps the modem locked to its
# network mode. Mirrors _profile_teardown_scenario_cron. Best-effort: never
# blocks the clear path.
_profile_reset_scenario_to_default() {
    if ! command -v scenario_reset_to_default >/dev/null 2>&1; then
        if [ -f /usr/lib/qmanager/scenario_mgr.sh ]; then
            . /usr/lib/qmanager/scenario_mgr.sh
        fi
    fi
    command -v scenario_reset_to_default >/dev/null 2>&1 && scenario_reset_to_default
    return 0
}

# _profile_emit_event <type> <message> <severity>
# Lazy-loads events.sh on first use with a no-op fallback if unavailable.
# Matches the EVENTS_FILE/MAX_EVENTS convention used by qmanager_profile_apply
# and qmanager_poller. Callers of profile_mgr.sh functions may not have
# events.sh sourced (e.g. the subshell pattern from poller/watchcat), so we
# lazy-source it on demand.
_profile_emit_event() {
    local etype
    local msg
    local severity
    etype="$1"
    msg="$2"
    severity="$3"
    if ! command -v append_event >/dev/null 2>&1; then
        [ -z "$EVENTS_FILE" ] && EVENTS_FILE="/tmp/qmanager_events.json"
        [ -z "$MAX_EVENTS" ] && MAX_EVENTS=50
        [ -f /usr/lib/qmanager/events.sh ] || return 0
        . /usr/lib/qmanager/events.sh
    fi
    command -v append_event >/dev/null 2>&1 && append_event "$etype" "$msg" "$severity" 2>/dev/null
    return 0
}

# auto_apply_profile <current_iccid> <caller_tag>
# Reconcile the active profile marker against the current SIM's ICCID.
#
#   - If a profile's sim_iccid matches the current ICCID, mark it active and
#     spawn the apply worker detached. The worker owns its own PID lock and
#     per-step skip logic — this helper does NOT pre-compare settings.
#   - If no profile matches AND the currently-active profile was pinned to a
#     different SIM, clear the active marker so the UI stops showing a stale
#     "Active" badge, and emit a profile_deactivated event (warning) to match
#     the poller's boot-time cleanup behavior. Profiles with empty sim_iccid
#     are left alone (not SIM-bound).
#
# Safe to call repeatedly (idempotent).
auto_apply_profile() {
    local current_iccid="$1"
    local caller="${2:-unknown}"
    local iccid_suffix
    local pf
    local pf_iccid
    local match_id
    local _ap_id
    local _ap_iccid
    local _ap_name
    local _ap_mno
    local _ap_cur_canon
    local _ap_live_len
    local _ap_cand_len

    if [ -z "$current_iccid" ]; then
        qlog_info "[$caller] auto_apply_profile: empty ICCID, skipping" 2>/dev/null
        return 1
    fi

    # Canonical form of the live ICCID for comparison (strips the trailing BCD
    # pad F so a stored digits-only value still matches). Compare-time only.
    _ap_cur_canon=$(iccid_canonicalize "$current_iccid")
    iccid_suffix=$(printf '%s' "$current_iccid" | tail -c 4)

    # A worker is already running. Don't drop this request (it may be a newer,
    # now-authoritative SIM) — queue it as pending. The running worker consumes
    # the marker on exit, AFTER releasing its PID lock, and re-runs auto_apply
    # for the freshest SIM. Atomic overwrite (tmp+mv) so latest wins with no torn
    # read. The old behavior (pure skip) silently lost a rapid back-to-back
    # switch when a stale worker was still applying the previous SIM's profile.
    if ! profile_check_lock; then
        # B4.1: mktemp sibling, not a fixed .tmp name a planted file could occupy
        _pa_tmp=$(mktemp "${PROFILE_PENDING_APPLY_FILE}.XXXXXX" 2>/dev/null)
        printf '%s\t%s\n' "$current_iccid" "$caller" > "$_pa_tmp" 2>/dev/null \
            && mv -f "$_pa_tmp" "$PROFILE_PENDING_APPLY_FILE" 2>/dev/null \
            || rm -f "$_pa_tmp" 2>/dev/null
        qlog_info "[$caller] Apply already running (PID $_profile_lock_pid); queued pending re-apply for ICCID ...$iccid_suffix" 2>/dev/null
        return 0
    fi

    match_id=""
    for pf in "$PROFILE_DIR"/p_*.json; do
        [ -f "$pf" ] || continue
        pf_iccid=$(jq -r '(.sim_iccid) | if . == null then empty else . end' "$pf" 2>/dev/null)
        if [ -n "$pf_iccid" ] && [ "$(iccid_canonicalize "$pf_iccid")" = "$_ap_cur_canon" ]; then
            match_id=$(jq -r '(.id) | if . == null then empty else . end' "$pf" 2>/dev/null)
            break
        fi
    done

    if [ -z "$match_id" ]; then
        # No profile matches the current SIM. If a SIM-pinned active profile
        # exists for a different SIM, clear the marker so the UI stops showing
        # a stale "Active" badge. Mirrors the poller's boot-time cleanup.
        _ap_id=$(get_active_profile)
        if [ -n "$_ap_id" ]; then
            _ap_iccid=$(jq -r '(.sim_iccid) | if . == null then empty else . end' "$PROFILE_DIR/${_ap_id}.json" 2>/dev/null)
            if [ -n "$_ap_iccid" ] && [ "$(iccid_canonicalize "$_ap_iccid")" != "$_ap_cur_canon" ]; then
                _ap_name=$(jq -r '(.name) | if . == null then empty else . end' "$PROFILE_DIR/${_ap_id}.json" 2>/dev/null)
                _ap_mno=$(jq -r '(.mno) | if . == null then empty else . end' "$PROFILE_DIR/${_ap_id}.json" 2>/dev/null)
                if [ "$_ap_mno" = "Verizon" ]; then
                    if mpdn_revert_to_default; then
                        _profile_emit_event "verizon_mpdn_reverted" "Verizon profile '${_ap_name:-unknown}' auto-deactivated (SIM mismatch). Data routing reverted — reboot required." "warning"
                    else
                        _profile_emit_event "verizon_mpdn_reverted" "Verizon profile '${_ap_name:-unknown}' auto-deactivated (SIM mismatch). MPDN revert verification failed — reboot recommended." "warning"
                    fi
                    : > /tmp/qmanager_pending_reboot_verizon
                fi
                clear_active_profile
                _profile_teardown_scenario_cron
                _profile_reset_scenario_to_default
                _profile_emit_event "profile_deactivated" "Profile '${_ap_name:-unknown}' auto-deactivated (SIM mismatch)" "warning"
                qlog_info "[$caller] Deactivated profile $_ap_id (SIM mismatch: current ICCID ...$iccid_suffix)" 2>/dev/null
            fi
        fi
        if [ "$(profile_count)" -gt 0 ]; then
            # Log the live ICCID and every candidate's stored sim_iccid with byte
            # lengths, so a format/pad mismatch is visible in one log read.
            _ap_live_len=$(printf '%s' "$current_iccid" | wc -c | tr -d ' ')
            qlog_warn "[$caller] No profile matches live ICCID '$current_iccid' (len=$_ap_live_len, canon='$_ap_cur_canon')" 2>/dev/null
            for pf in "$PROFILE_DIR"/p_*.json; do
                [ -f "$pf" ] || continue
                _ap_id=$(jq -r '(.id) | if . == null then empty else . end' "$pf" 2>/dev/null)
                pf_iccid=$(jq -r '(.sim_iccid) | if . == null then empty else . end' "$pf" 2>/dev/null)
                _ap_cand_len=$(printf '%s' "$pf_iccid" | wc -c | tr -d ' ')
                qlog_warn "[$caller]   candidate $_ap_id stored sim_iccid='$pf_iccid' (len=$_ap_cand_len)" 2>/dev/null
            done
        fi
        return 1
    fi

    set_active_profile "$match_id" || return 1
    qlog_info "[$caller] Auto-applying profile $match_id (ICCID ...$iccid_suffix)" 2>/dev/null
    # --auto enables the worker's stale-SIM guard so a switch that supersedes
    # this apply mid-flight can't finalize the wrong SIM's profile.
    ( /usr/bin/qmanager_profile_apply "$match_id" --auto </dev/null >/dev/null 2>&1 & )
    return 0
}

# =============================================================================
# AT Command Conversion Helpers
# =============================================================================

# NOTE: mode_to_at() and at_to_mode() removed — band locking and network mode
# are now owned by Connection Scenarios, not SIM Profiles. These helpers will
# be reimplemented in the Connection Scenarios library when that feature is built.

# =============================================================================
# Apply Lock Helpers (Worker PID Lock + CGI Spawn Lock)
# =============================================================================
# Two distinct concerns, two files:
#   - $PROFILE_APPLY_PID_FILE  — owned by the worker (qmanager_profile_apply).
#                                 Singleton enforcement.
#   - $PROFILE_SPAWN_LOCK_FILE — owned by the CGI (apply.sh). Rejects
#                                 concurrent POSTs while the worker comes up.
# Collapsing both onto one file caused the worker to abort because the CGI's
# kill -0 check found the still-sleeping CGI parent. See plan 2026-05-03.
# =============================================================================

# profile_check_lock
# Check if a profile apply process is currently running.
# Returns 0 if free (stale PID cleaned), 1 if locked.
# On lock, sets global: _profile_lock_pid
profile_check_lock() {
    if [ -f "$PROFILE_APPLY_PID_FILE" ]; then
        _profile_lock_pid=$(cat "$PROFILE_APPLY_PID_FILE" 2>/dev/null)
        if [ -n "$_profile_lock_pid" ] && kill -0 "$_profile_lock_pid" 2>/dev/null; then
            return 1
        fi
        rm -f "$PROFILE_APPLY_PID_FILE"
    fi
    _profile_lock_pid=""
    return 0
}

# profile_acquire_lock
# Check + acquire the profile apply lock (writes $$ to PID file).
# Returns 0 on success, 1 if already locked.
profile_acquire_lock() {
    profile_check_lock || return 1
    echo $$ > "$PROFILE_APPLY_PID_FILE" || {
        qlog_error "Failed to write PID file" 2>/dev/null
        return 1
    }
    return 0
}

# profile_acquire_spawn_lock
# CGI-side spawn mutex. Atomically creates $PROFILE_SPAWN_LOCK_FILE with the
# caller's PID. Distinct from profile_acquire_lock — that one belongs to the
# worker. Stale spawn-locks (PID dead) are reaped before acquire.
# Returns 0 on success, 1 if a live spawner already holds it.
# Global _profile_spawn_lock_pid: cleared on success (caller holds the lock);
# set to the holding PID on failure (caller may log it).
profile_acquire_spawn_lock() {
    if [ -f "$PROFILE_SPAWN_LOCK_FILE" ]; then
        _profile_spawn_lock_pid=$(cat "$PROFILE_SPAWN_LOCK_FILE" 2>/dev/null)
        if [ -n "$_profile_spawn_lock_pid" ] && kill -0 "$_profile_spawn_lock_pid" 2>/dev/null; then
            return 1
        fi
        rm -f "$PROFILE_SPAWN_LOCK_FILE"
    fi
    # Atomic create via noclobber. If another shell wins the race, the redirect
    # fails and we return 1 without clobbering. The subshell isolates `set -C`
    # so the caller's shell options are unaffected.
    ( set -C; echo $$ > "$PROFILE_SPAWN_LOCK_FILE" ) 2>/dev/null || {
        # Re-read in case the winner is alive — caller treats either as "locked".
        _profile_spawn_lock_pid=$(cat "$PROFILE_SPAWN_LOCK_FILE" 2>/dev/null)
        return 1
    }
    _profile_spawn_lock_pid=""
    return 0
}

# profile_release_spawn_lock
# Removes the spawn-lock file. Safe to call unconditionally on every CGI exit
# path — rm -f does not fail on a missing file.
profile_release_spawn_lock() {
    rm -f "$PROFILE_SPAWN_LOCK_FILE"
}

# =============================================================================
# MPDN Rule Management (Verizon workaround)
# =============================================================================
# Verizon requires data to flow through PDP context 3 (not the default 1).
# These helpers read/write QMAP MPDN rules and verify USB net mode compatibility.
#
# AT response formats:
#   AT+QMAP="WWAN"   → +QMAP: "WWAN",<connected>,<pdp>,"IPV4","..."
#   AT+QCFG="usbnet" → +QCFG: "usbnet",<mode>
#
# NOTE: every helper here is QMAP-intrinsic. Firmware without AT+QMAP (e.g.
# RM551E-GL fw ...R02A01M8G answers ERROR to every form) cannot run Verizon
# MPDN at all; mpdn_get_active_pdp then returns empty. To learn the data CID on
# any firmware use data_cid.sh (qm_detect_data_cid) instead. Known follow-up.
#
# USB net mode compatibility: 1=ECM, 3=RNDIS (supported); 0=RMNet, 2=MBIM (not supported)
# =============================================================================

# mpdn_get_active_pdp
# Reads the active PDP context number reported by AT+QMAP="WWAN".
# Echoes the integer (e.g. "1" or "3") to stdout, or empty string if not
# connected / response cannot be parsed.
# Returns 0 always — callers check the echoed value.
mpdn_get_active_pdp() {
    local response
    local pdp
    response=$(qcmd 'AT+QMAP="WWAN"' 2>/dev/null)
    # Line format: +QMAP: "WWAN",<connected>,<pdp>,"IPV4","..."
    # $1=+QMAP: "WWAN"  $2=<connected>  $3=<pdp>
    pdp=$(printf '%s' "$response" | awk -F',' '/\+QMAP:.*"WWAN"/{
        cid=$3; gsub(/[^0-9]/, "", cid); if (cid != "") { print cid; exit }
    }')
    printf '%s' "$pdp"
    return 0
}

# usb_mode_supports_mpdn
# Returns 0 (success) if the current USB net mode supports MPDN (ECM=1 or RNDIS=3).
# Returns 1 for unsupported modes (RMNet=0, MBIM=2) or on parse failure.
usb_mode_supports_mpdn() {
    local response
    local mode
    response=$(qcmd 'AT+QCFG="usbnet"' 2>/dev/null)
    mode=$(printf '%s' "$response" | awk -F',' '/\+QCFG:.*"usbnet"/{print $2+0; exit}')
    case "$mode" in
        1|3) return 0 ;;
        *)   return 1 ;;
    esac
}

# mpdn_apply_verizon
# Configures MPDN rule 0 to route through PDP context 3 (Verizon requirement).
# Idempotent: skips if already on PDP 3.
# Returns 0 on success, 1 if verification fails after applying.
mpdn_apply_verizon() {
    local current_pdp
    current_pdp=$(mpdn_get_active_pdp)

    if [ "$current_pdp" = "3" ]; then
        qlog_info "MPDN already on PDP context 3, skipping" 2>/dev/null
        return 0
    fi

    qlog_info "Applying Verizon MPDN rule: PDP context 3" 2>/dev/null
    qcmd 'AT+QMAP="mpdn_rule",0,3,0,0,1' >/dev/null 2>&1

    sleep 1

    local verified_pdp
    verified_pdp=$(mpdn_get_active_pdp)
    if [ "$verified_pdp" = "3" ]; then
        qlog_info "MPDN rule applied: active PDP context is 3" 2>/dev/null
        return 0
    fi

    qlog_error "MPDN apply verification failed: expected PDP 3, got '${verified_pdp:-<empty>}'" 2>/dev/null
    return 1
}

# mpdn_revert_to_default
# Reverts MPDN rule 0 back to PDP context 1 (modem default).
# IMPORTANT: release and re-set are issued back-to-back with NO sleep between
# them. The modem must never be left in a bare-released state — doing so
# requires a firmware re-flash to recover.
# Returns 0 on success, 1 if verification fails (but the release+re-set pair
# is always sent regardless of the verification outcome).
mpdn_revert_to_default() {
    qlog_info "Reverting MPDN rule to PDP context 1 (default)" 2>/dev/null

    # Release then immediately re-pin — NO sleep between (firmware quirk).
    qcmd 'AT+QMAP="mpdn_rule",0' >/dev/null 2>&1
    # !!! DO NOT INSERT ANYTHING BETWEEN THESE TWO LINES !!!
    # A bare release followed by reboot bricks the modem until firmware reflash.
    qcmd 'AT+QMAP="mpdn_rule",0,1,0,0,1' >/dev/null 2>&1

    sleep 1

    local verified_pdp
    verified_pdp=$(mpdn_get_active_pdp)
    if [ "$verified_pdp" = "1" ]; then
        qlog_info "MPDN rule reverted: active PDP context is 1" 2>/dev/null
        return 0
    fi

    qlog_error "MPDN revert verification failed: expected PDP 1, got '${verified_pdp:-<empty>}'" 2>/dev/null
    return 1
}
