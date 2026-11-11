#!/bin/sh
# =============================================================================
# apn_mgr.sh — QManager APN (v2 slot model) Manager Library
# =============================================================================
# A sourceable library providing the v2 5-slot APN config I/O, PDP-type
# vocabulary conversion, the COPS detach/attach apply cycle, and the
# "reapply the active slot to the modem" helper used when a Custom SIM Profile
# is deactivated (so the live APN matches what APN Management badges as Active).
#
# This is a LIBRARY — no persistent process, no polling. CGI scripts source it
# and call functions directly.
#
# MODEL (v2): the device keeps exactly FIVE stored data-profile slots (ids 1-5)
# in a JSON sidecar, plus a single "active" pointer. There is only ever ONE
# active slot. Invariant on every path: a slot with an EMPTY apn is never
# `active`.
#
# Dependencies: run_at (from cgi_at.sh, sourced below), qlog_* (from
# cgi_base.sh / qlog.sh — the caller is expected to have sourced one already;
# cgi_at.sh installs a no-op qlog_warn fallback if not), jq.
# Install location: /usr/lib/qmanager/apn_mgr.sh
#
# Usage:
#   . /usr/lib/qmanager/apn_mgr.sh
#   read_config_v2                         → valid 5-slot v2 JSON on stdout
#   write_config_v2 <json>                 → atomic write; rc 1 on failure
#   apply_apn_to_modem <cid> <pdp> <apn>   → COPS cycle; rc 1 + APN_APPLY_ERR_*
#   reapply_active_apn_slot                → restore active slot to modem
# =============================================================================

[ -n "$_APN_MGR_LOADED" ] && return 0
_APN_MGR_LOADED=1

# run_at lives in cgi_at.sh. Source it for self-containment — it has a
# load-guard and no side effects on source, so this is idempotent even when the
# caller already sourced it.
. /usr/lib/qmanager/cgi_at.sh

# --- Configuration -----------------------------------------------------------
MAX_SLOTS=5                                          # stored profile slots (ids 1-5)
MAX_CID=6                                            # modem PDP contexts surfaced
PROFILE_FILE="/usrdata/qmanager/apn_profiles.json"
LEGACY_NAME_FILE="/usrdata/qmanager/apn_names.json"

# PDP type <-> frontend vocabulary. AT+CGDCONT uses IP/IPV6/IPV4V6; the UI
# uses ipv4/ipv6/ipv4v6.
pdp_to_frontend() {
    case "$1" in
        IP|IPV4) echo "ipv4" ;;
        IPV6)    echo "ipv6" ;;
        IPV4V6)  echo "ipv4v6" ;;
        *)       echo "" ;;
    esac
}
pdp_to_at() {
    case "$1" in
        ipv4)   echo "IP" ;;
        ipv6)   echo "IPV6" ;;
        ipv4v6) echo "IPV4V6" ;;
        *)      echo "" ;;
    esac
}

# --- v2 config read ----------------------------------------------------------
# read_config_v2 — always print a VALID 5-slot v2 JSON object on stdout. Never
# errors: a missing or corrupt file yields a fresh empty v2 doc. Performs the
# one-time migration from prior on-disk shapes and writes the migrated doc back
# so the next read is a straight load.
#
# Migration precedence:
#   1. Already v2 (has version==2 and a profiles array)  -> normalize to 5 slots.
#   2. Old shape {"<cid>":{name,apn,pdp_type}}           -> lowest cid -> slot 1
#                                                           (active=1 if apn set).
#   3. Legacy apn_names.json {"<cid>":"<name>"}          -> lowest cid name ->
#                                                           slot 1, no apn,
#                                                           active=0.
#   4. Nothing                                           -> 5 empty slots,
#                                                           active=0.
#
# Invariant enforced on every path: a slot with an EMPTY apn is never `active`.
EMPTY_V2='{"version":2,"active":0,"profiles":[{"id":1,"name":"","apn":"","pdp_type":"ipv4v6","cid":1},{"id":2,"name":"","apn":"","pdp_type":"ipv4v6","cid":1},{"id":3,"name":"","apn":"","pdp_type":"ipv4v6","cid":1},{"id":4,"name":"","apn":"","pdp_type":"ipv4v6","cid":1},{"id":5,"name":"","apn":"","pdp_type":"ipv4v6","cid":1}]}'

# normalize_v2 <raw_v2_json> — coerce an arbitrary v2-ish object into exactly 5
# ordered slots (ids 1-5), each field type-checked and null-guarded, with the
# empty-slot-cannot-be-active invariant applied. Prints normalized JSON, or
# nothing (rc 1) if the input is not valid JSON.
normalize_v2() {
    printf '%s' "$1" | jq -c '
        # Index incoming profiles by id for lookup; tolerate a missing array.
        ( (if .profiles == null then [] else .profiles end)
          | map(select(type == "object"))
          | map({ key: ((if .id == null then 0 else .id end) | tostring), value: . })
          | from_entries
        ) as $by
        | (if .active == null then 0 else (.active | if type == "number" then . else 0 end) end) as $rawactive
        | { version: 2,
            profiles: ( [ range(1;6) as $i
              | (($by[($i|tostring)]) | if . == null then {} else . end) as $s
              | { id: $i,
                  name: (if $s.name == null then "" else ($s.name | tostring) end),
                  apn:  (if $s.apn  == null then "" else ($s.apn  | tostring) end),
                  pdp_type: (
                      (if $s.pdp_type == null then "ipv4v6" else ($s.pdp_type | tostring) end) as $p
                      | if ($p == "ipv4" or $p == "ipv6" or $p == "ipv4v6") then $p else "ipv4v6" end
                  ),
                  cid: (
                      (if $s.cid == null then 1 else $s.cid end) as $c
                      | (if ($c | type) == "number" then $c else 1 end) as $c
                      | if ($c >= 1 and $c <= 6) then $c else 1 end
                  )
                } ] )
          }
        # Enforce: active must point at a 1-5 slot whose apn is non-empty.
        | . as $doc
        | ( $doc.profiles | map(select(.apn != "") | .id) ) as $eligible
        | .active = (if ($eligible | index($rawactive)) != null then $rawactive else 0 end)
    ' 2>/dev/null
}

read_config_v2() {
    _rc_raw=""
    if [ -f "$PROFILE_FILE" ]; then
        _rc_raw=$(jq -c '.' "$PROFILE_FILE" 2>/dev/null)
    fi

    # --- Path 1: already a v2 doc -> normalize, persist if it changed. -------
    if [ -n "$_rc_raw" ]; then
        _rc_isv2=$(printf '%s' "$_rc_raw" | jq -r '
            if (.version == 2 and (.profiles | type) == "array") then "yes" else "no" end' 2>/dev/null)
        if [ "$_rc_isv2" = "yes" ]; then
            _rc_norm=$(normalize_v2 "$_rc_raw")
            [ -z "$_rc_norm" ] && _rc_norm="$EMPTY_V2"
            # Re-persist only when normalization actually changed the bytes, so
            # a steady-state read does not churn the file on every GET.
            if [ "$_rc_norm" != "$_rc_raw" ]; then
                write_config_v2 "$_rc_norm" || qlog_warn "read_config_v2: re-persist after normalize failed"
            fi
            printf '%s' "$_rc_norm"
            return 0
        fi
    fi

    # --- Path 2: old shape {"<cid>":{name,apn,pdp_type}} --------------------
    # Detect by: object whose first value is itself an object carrying apn/name.
    if [ -n "$_rc_raw" ]; then
        _rc_v2_from_old=$(printf '%s' "$_rc_raw" | jq -c '
            # Numeric-keyed cid -> object map. Take the lowest cid key.
            ( to_entries
              | map(select((.value | type) == "object"))
              | map(. + { _k: (.key | (tonumber? // null) | if . == null then 0 else . end) })
              | sort_by(._k)
            ) as $sorted
            | if ($sorted | length) == 0 then null
              else
                $sorted[0] as $first
                | ($first._k) as $cid
                | ($first.value) as $v
                | (if $v.name == null then "" else ($v.name | tostring) end) as $name
                | (if $v.apn  == null then "" else ($v.apn  | tostring) end) as $apn
                | ((if $v.pdp_type == null then "ipv4v6" else ($v.pdp_type | tostring) end)
                   | if (. == "ipv4" or . == "ipv6" or . == "ipv4v6") then . else "ipv4v6" end) as $pdp
                | (if ($cid >= 1 and $cid <= 6) then $cid else 1 end) as $cid
                | { version: 2,
                    active: (if $apn == "" then 0 else 1 end),
                    profiles: ( [ { id: 1, name: $name, apn: $apn, pdp_type: $pdp, cid: $cid } ]
                                + ( [ range(2;6) as $i
                                      | { id: $i, name: "", apn: "", pdp_type: "ipv4v6", cid: 1 } ] ) )
                  }
              end
        ' 2>/dev/null)
        if [ -n "$_rc_v2_from_old" ] && [ "$_rc_v2_from_old" != "null" ]; then
            _rc_norm=$(normalize_v2 "$_rc_v2_from_old")
            [ -z "$_rc_norm" ] && _rc_norm="$EMPTY_V2"
            write_config_v2 "$_rc_norm" || qlog_warn "read_config_v2: persist of migrated (old-shape) doc failed"
            qlog_info "Migrated apn_profiles.json from old cid-keyed shape to v2"
            printf '%s' "$_rc_norm"
            return 0
        fi
    fi

    # --- Path 3: legacy apn_names.json {"<cid>":"<name>"} ------------------
    if [ -f "$LEGACY_NAME_FILE" ]; then
        _rc_v2_from_names=$(jq -c '
            ( to_entries
              | map(select((.value | type) == "string"))
              | map(. + { _k: (.key | (tonumber? // null) | if . == null then 0 else . end) })
              | sort_by(._k)
            ) as $sorted
            | if ($sorted | length) == 0 then null
              else
                $sorted[0] as $first
                | (if ($first._k >= 1 and $first._k <= 6) then $first._k else 1 end) as $cid
                | { version: 2,
                    active: 0,
                    profiles: ( [ { id: 1, name: ($first.value | tostring),
                                    apn: "", pdp_type: "ipv4v6", cid: $cid } ]
                                + ( [ range(2;6) as $i
                                      | { id: $i, name: "", apn: "", pdp_type: "ipv4v6", cid: 1 } ] ) )
                  }
              end
        ' "$LEGACY_NAME_FILE" 2>/dev/null)
        if [ -n "$_rc_v2_from_names" ] && [ "$_rc_v2_from_names" != "null" ]; then
            _rc_norm=$(normalize_v2 "$_rc_v2_from_names")
            [ -z "$_rc_norm" ] && _rc_norm="$EMPTY_V2"
            write_config_v2 "$_rc_norm" || qlog_warn "read_config_v2: persist of migrated (legacy names) doc failed"
            qlog_info "Migrated legacy apn_names.json to v2 apn_profiles.json"
            printf '%s' "$_rc_norm"
            return 0
        fi
    fi

    # --- Path 4: nothing usable -> fresh empty v2 (persist so it's stable). --
    write_config_v2 "$EMPTY_V2" || qlog_warn "read_config_v2: persist of fresh empty v2 failed"
    printf '%s' "$EMPTY_V2"
    return 0
}

# write_config_v2 <json> — atomic write of the full v2 config object. Written
# by www-data (CGI runs as www-data; /usrdata/qmanager is world-writable), then
# chmod 644 on both the temp file (before move) and the final path (after), so
# the mode does not depend on the CGI process umask. Returns 1 on any failure.
write_config_v2() {
    _wc_json="$1"
    # Guard: never write non-JSON / empty content over the config.
    printf '%s' "$_wc_json" | jq -e '.' >/dev/null 2>&1 || return 1
    _wc_dir=$(dirname "$PROFILE_FILE")
    [ -d "$_wc_dir" ] || mkdir -p "$_wc_dir" 2>/dev/null
    _wc_tmp="${PROFILE_FILE}.tmp.$$"
    printf '%s\n' "$_wc_json" > "$_wc_tmp" 2>/dev/null || return 1
    chmod 644 "$_wc_tmp" 2>/dev/null
    mv "$_wc_tmp" "$PROFILE_FILE" 2>/dev/null || { rm -f "$_wc_tmp" 2>/dev/null; return 1; }
    chmod 644 "$PROFILE_FILE" 2>/dev/null
    return 0
}

# cops_recover — best-effort re-register on a post-detach error path. Never
# leave the modem detached after a partial APN write. Shared by save+activate.
cops_recover() { run_at "AT+COPS=0" >/dev/null 2>&1 || true; }

# apply_apn_to_modem <cid> <pdp_at> <apn> — drive the COPS detach/attach cycle
# that negotiates a new APN at attach time. RETURN-CODE-BASED: on failure it
# sets APN_APPLY_ERR_CODE / APN_APPLY_ERR_DETAIL and returns 1 (after
# cops_recover() on the CGDCONT path where the modem may be left detached);
# returns 0 on success. The caller decides how to surface the failure (a CGI
# caller die()s on it; deactivate.sh warns and proceeds).
#
# Why a full attach cycle (not AT+CGACT=0/1): on EPS (LTE / 5G-NSA) the default
# EPS bearer is established at *attach time* and the APN is a contract field
# with the MME/PGW. AT+CGACT only cycles the user-plane of an already-
# established bearer — the MME keeps the original APN, so the new CGDCONT value
# never reaches the network. AT+COPS=2 forces a full detach; the subsequent
# AT+COPS=0 attach carries the freshly-written APN and the PGW builds a new
# bearer. No sleeps: run_at goes through qcmd's flock, synchronous on OK/ERROR.
# The cellular WAN drops briefly but the LAN/Wi-Fi HTTP path to the modem does
# not, so the in-flight CGI response is unaffected. NO reboot, NO AT+CFUN.
apply_apn_to_modem() {
    _am_cid="$1"
    _am_pdp="$2"
    _am_apn="$3"
    APN_APPLY_ERR_CODE=""
    APN_APPLY_ERR_DETAIL=""

    # Step 1: deregister from the network.
    if ! run_at "AT+COPS=2" >/dev/null; then
        APN_APPLY_ERR_CODE="cops_detach_failed"
        APN_APPLY_ERR_DETAIL="AT+COPS=2 (deregister) failed for CID $_am_cid"
        return 1
    fi
    # Step 2: write APN + PDP type.
    if ! run_at "AT+CGDCONT=$_am_cid,\"$_am_pdp\",\"$_am_apn\"" >/dev/null; then
        cops_recover
        APN_APPLY_ERR_CODE="cgdcont_failed"
        APN_APPLY_ERR_DETAIL="AT+CGDCONT failed for CID $_am_cid"
        return 1
    fi
    # Step 3: re-register so the modem attaches with the new APN.
    if ! run_at "AT+COPS=0" >/dev/null; then
        APN_APPLY_ERR_CODE="cops_attach_failed"
        APN_APPLY_ERR_DETAIL="AT+COPS=0 (re-register) failed for CID $_am_cid"
        return 1
    fi
    # Force an early poller Tier-2 refresh so the UI (and adaptive-backoff Idle/
    # Deep tiers) reflect the new identity/registration state within ~2s. This is
    # the single success chokepoint for every APN apply — user-initiated
    # (apn.sh CGI), profile-deactivation reapply, and boot reconcile all run
    # through here. Detached so it never blocks the caller; idempotent (touch of
    # an existing flag no-ops).
    #
    # The APN / WAN / DNS display fields are no longer read by the poller (they
    # were relocated on-demand for L1 safety), so force_tier2 alone would NOT
    # refresh the displayed APN after an apply. Refresh the on-demand data-plane
    # cache directly here — CGCONTRDP / QMAP only, NO L1/mimo read — so the UI
    # shows the new APN immediately. Guarded: ondemand_radio.sh is only loaded in
    # contexts that sourced it; absent, we degrade to "APN updates next page open".
    (
        sleep 2
        touch /tmp/qmanager_force_tier2
        # Source the on-demand libs inside the subshell so the refresh works no
        # matter which context sourced apn_mgr.sh (CGI apn.sh, boot reconcile,
        # profile deactivate). parse_at.sh provides the parsers ondemand_radio.sh
        # depends on. Both guarded; absent -> APN simply updates on next page open.
        if [ -f /usr/lib/qmanager/ondemand_radio.sh ] && [ -f /usr/lib/qmanager/parse_at.sh ]; then
            . /usr/lib/qmanager/parse_at.sh
            . /usr/lib/qmanager/ondemand_radio.sh
            command -v ondemand_dataplane_refresh >/dev/null 2>&1 && ondemand_dataplane_refresh
        fi
    ) </dev/null >/dev/null 2>&1 &
    return 0
}

# reapply_active_apn_slot — restore APN Management's active slot to the modem so
# the live APN matches the slot the UI badges as "Active". Used after a Custom
# SIM Profile is deactivated (the profile left its own APN on the modem).
#
# Resolution:
#   - active != 0 and that slot has a non-empty apn  -> reapply that slot.
#   - active == 0 (carrier-default)                  -> no-op (carrier-assigned
#       APN is left untouched; NEVER auto-resurrects a slot), return 0.
#
# Best-effort modem apply: on apply failure, propagate return 1 with
# APN_APPLY_ERR_* set; the caller decides whether to fail. On a successful
# apply, prints the applied slot id on stdout (empty on no-op).
reapply_active_apn_slot() {
    _ra_config=$(read_config_v2)
    _ra_active=$(printf '%s' "$_ra_config" | jq -r '.active')

    # active == 0 (or empty) is a deliberate carrier-default choice: leave the
    # live carrier-assigned APN untouched and never auto-resurrect a slot.
    if [ "$_ra_active" = "0" ] || [ -z "$_ra_active" ]; then
        qlog_info "Reapply active APN slot: active=0, carrier-default preserved (no-op)"
        return 0
    fi
    _ra_target="$_ra_active"

    # Load the resolved slot's fields.
    _ra_apn=$(printf '%s' "$_ra_config" | jq -r \
        --argjson id "$_ra_target" '.profiles[] | select(.id == $id) | .apn')
    _ra_pdp=$(printf '%s' "$_ra_config" | jq -r \
        --argjson id "$_ra_target" '.profiles[] | select(.id == $id) | .pdp_type')
    _ra_cid=$(printf '%s' "$_ra_config" | jq -r \
        --argjson id "$_ra_target" '.profiles[] | select(.id == $id) | .cid')

    # Guard: an active pointer at an empty slot should not happen (normalize_v2
    # forbids it), but never drive an empty APN into the modem.
    [ -z "$_ra_apn" ] && return 0

    _ra_pdp_at=$(pdp_to_at "$_ra_pdp")
    [ -z "$_ra_pdp_at" ] && _ra_pdp_at="IPV4V6"

    qlog_info "Reapply active APN slot $_ra_target: apn=$_ra_apn pdp=$_ra_pdp_at cid=$_ra_cid"

    if ! apply_apn_to_modem "$_ra_cid" "$_ra_pdp_at" "$_ra_apn"; then
        return 1
    fi

    printf '%s' "$_ra_target"
    return 0
}

# reconcile_active_apn_slot_at_boot — IDEMPOTENT boot-time replay of the active
# APN slot onto the modem. Called once from the poller's boot sequence.
#
# WHY this exists: the user PDP context's APN does NOT survive in modem NVRAM
# across a power-cycle (carrier-provisioned ims/sos contexts on CID 2/3 do, but
# the user data context comes back empty/carrier-default). The 5-slot APN
# Management config persists the active slot in apn_profiles.json; nothing else
# replays it at boot, so the active slot is effectively un-applied after a
# reboot unless we reconcile it here.
#
# DISTINCT from reapply_active_apn_slot: that one applies UNCONDITIONALLY (used
# right after a Custom SIM Profile deactivation, where the profile is known to
# have left its own APN on the modem). This one is IDEMPOTENT — it compares the
# stored slot APN against the live AT+CGDCONT? value for the slot's CID and runs
# the COPS detach/attach cycle ONLY on mismatch. An unconditional reapply would
# drop the WAN on every clean boot; live recon confirmed the active slot already
# matches live in the common case, so this fires ZERO AT commands then.
#
# GATING: skipped when (a) a Custom SIM Profile is active (the profile owns the
# APN and auto-applies separately — profile authority wins) or (b) no slot is
# active (active=0 is the deliberate carrier-default no-op).
#
# This is the relocation of the retired qmanager_wan_guard boot reconcile. The
# bind-disable pass that used to accompany it in wan_guard was DROPPED as
# obsolete (no longer relocated).
#
# Fully fail-safe: every path returns, NEVER reboots, NEVER touches AT+CFUN.
reconcile_active_apn_slot_at_boot() {
    # 1. Profile authority wins — if a Custom SIM Profile owns the APN at boot,
    #    it is applied separately via auto_apply_profile. Marker presence is
    #    enough; do not touch the slot.
    if [ -s /etc/qmanager/active_profile ]; then
        qlog_info "Custom SIM Profile active — skipping APN-slot boot reconcile"
        return 0
    fi

    # 2. Resolve the active slot via the lib's own reader.
    _rc_config=$(read_config_v2)
    _rc_active=$(printf '%s' "$_rc_config" | jq -r '.active')
    if [ "$_rc_active" = "0" ] || [ -z "$_rc_active" ] || [ "$_rc_active" = "null" ]; then
        qlog_info "No active APN slot — nothing to reconcile at boot"
        return 0
    fi

    # 3. Load the active slot's fields.
    _rc_apn=$(printf '%s' "$_rc_config" | jq -r \
        --argjson id "$_rc_active" '.profiles[] | select(.id == $id) | .apn')
    _rc_pdp=$(printf '%s' "$_rc_config" | jq -r \
        --argjson id "$_rc_active" '.profiles[] | select(.id == $id) | .pdp_type')
    _rc_cid=$(printf '%s' "$_rc_config" | jq -r \
        --argjson id "$_rc_active" '.profiles[] | select(.id == $id) | .cid')

    if [ -z "$_rc_apn" ] || [ "$_rc_apn" = "null" ]; then
        qlog_info "Active slot has empty APN — nothing to reconcile"
        return 0
    fi
    case "$_rc_cid" in
        ''|*[!0-9]*) _rc_cid=1 ;;
    esac

    # 4. PDP token (default IPV4V6).
    _rc_pdp_at=$(pdp_to_at "$_rc_pdp")
    [ -z "$_rc_pdp_at" ] && _rc_pdp_at="IPV4V6"

    # 5. Idempotent compare: query the live contexts ONCE.
    _rc_cgdcont=$(run_at "AT+CGDCONT?")
    if [ -z "$_rc_cgdcont" ]; then
        qlog_warn "AT+CGDCONT? empty at boot reconcile — skipping (fail-safe)"
        return 0
    fi
    # Extract the live apn for the target cid (ported from wan_guard's
    # _am_live_apn_for_cid, but reading the local snapshot not a global).
    _rc_live_apn=$(printf '%s' "$_rc_cgdcont" | awk -F',' -v want="$_rc_cid" '
        /\+CGDCONT:/ {
            cid = $1; gsub(/[^0-9]/, "", cid)
            apn = $3; gsub(/"/, "", apn)
            if (cid == want) { print apn; exit }
        }
    ')

    # 6. Skip on match — the common clean-boot case, zero AT commands.
    # 3GPP APNs are case-insensitive: compare lowercased so a case-only
    # difference never triggers a needless COPS cycle (WAN drop).
    _rc_live_lc=$(printf '%s' "$_rc_live_apn" | tr 'A-Z' 'a-z')
    _rc_apn_lc=$(printf '%s' "$_rc_apn" | tr 'A-Z' 'a-z')
    if [ "$_rc_live_lc" = "$_rc_apn_lc" ]; then
        qlog_info "APN already correct for CID $_rc_cid — no boot reconcile needed"
        return 0
    fi

    # 7. Mismatch — re-apply via the shared COPS detach/attach cycle.
    qlog_warn "Boot reconcile APN for CID $_rc_cid: stored=$_rc_apn live=$_rc_live_apn"
    if ! apply_apn_to_modem "$_rc_cid" "$_rc_pdp_at" "$_rc_apn"; then
        qlog_error "Boot reconcile failed for CID $_rc_cid: $APN_APPLY_ERR_CODE"
        return 1
    fi
    qlog_info "Boot reconcile complete for CID $_rc_cid"
    return 0
}
