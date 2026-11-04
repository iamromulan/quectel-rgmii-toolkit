#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/cgi_at.sh
. /usr/lib/qmanager/apn_mgr.sh
[ -f /usr/lib/qmanager/data_cid.sh ] && . /usr/lib/qmanager/data_cid.sh
# =============================================================================
# apn.sh — CGI Endpoint: APN Settings (GET + POST), AT-only
# =============================================================================
# RM551E-GL / RM520N-GL have no Casa RDB key-value store and no wmmd daemon, so
# every live profile field is sourced directly from AT commands through qcmd.
#
# MODEL (single APN): the device keeps the same 5-slot JSON sidecar
# (/usrdata/qmanager/apn_profiles.json, v2), but this surface treats SLOT 1 as
# the single user APN. Slots 2–5 go unused. active=1 means a custom APN is
# live; active=0 means carrier-default. All boot-reconcile, reapply, and Custom
# SIM Profile authority machinery already key off "the active slot," so they
# continue to work unchanged with no migration needed.
#
# Separately, the GET response still surfaces the modem's raw context table
# (CIDs 1-6) under `cids`, with IMS/SOS contexts TAGGED (not dropped) via
# qm_apn_class(), so the UI can show what each hardware context currently holds.
#
# "Active CID" (the live data-bearing context) comes from data_cid.sh: the
# CGPADDR addresses of one compound query confirmed against the kernel's
# default-route source / local addresses. No QMAP (several firmwares, e.g.
# RM551E-GL, do not implement it and a single ERROR kills the whole reply).
#
# GET  -> { active, active_cid, internet_cid, data_cid_source,
#           apn{apn,pdp_type,cid}, cids[6]{..., activated} }
# POST -> {"action":"save"|"deactivate", ...} applies a change.
#
# AT commands used (GET):
#   AT+CGDCONT?;+CGACT?;+CGPADDR                -> one round-trip, three sections
#     +CGDCONT: defined PDP contexts (CID, PDP type, APN)
#     +CGACT:   per-context activation state
#     +CGPADDR: per-CID assigned IP (data-CID detection)
#
# AT commands used (POST save):
#   AT+COPS=2                            -> deregister  (force full detach)
#   AT+CGDCONT=<cid>,"<PDP_AT>","<apn>"  -> define APN + PDP type
#   AT+COPS=0                            -> re-register (attaches with new APN)
#
# AT commands used (POST deactivate):
#   AT+COPS=2                            -> deregister
#   AT+CGDCONT=<cid>,"<PDP_AT>",""      -> blank APN (forces carrier default)
#   AT+COPS=0                            -> re-register
#
# Endpoint: GET/POST /cgi-bin/quecmanager/cellular/apn.sh
# Install location: <docroot>/cgi-bin/quecmanager/cellular/apn.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_apn"
cgi_headers
cgi_handle_options

# =============================================================================
# Helpers
# =============================================================================
# v2 config I/O (MAX_SLOTS, MAX_CID, PROFILE_FILE, LEGACY_NAME_FILE, EMPTY_V2,
# pdp_to_at/pdp_to_frontend, normalize_v2, read_config_v2, write_config_v2),
# the COPS apply cycle (apply_apn_to_modem, cops_recover) and the active-slot
# reapply helper all live in /usr/lib/qmanager/apn_mgr.sh (sourced above).

# die <error_code> <detail> — emit a JSON error and stop. CGI exits 0; the
# client distinguishes success via the "success" field, not the HTTP status.
die() {
    qlog_error "$1: ${2:-}"
    cgi_error "$1" "${2:-}"
    exit 0
}

# =============================================================================
# GET — slot-1 APN + raw modem context table
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Fetching APN settings (v2 slot-1, AT)"

    command -v qm_detect_data_cid >/dev/null 2>&1 || die "parse_failed" "Data-context detection is unavailable"

    # One compound call. Each qcmd invocation carries a fixed per-call cost
    # (process spawn + flock + modem channel handshake) that dominates the AT
    # payload itself; chaining the three queries pays that cost once. A
    # transport failure (rc 1) happens transiently right after a COPS attach
    # (AT channel busy) and gets one immediate retry. A modem ERROR (rc 2) keeps
    # whatever sections were answered: only "no +CGDCONT at all" is a failure.
    # A sustained failure must surface honestly via die() -- returning active:1
    # with an all-empty cids[] would make the frontend badge mis-read the stored
    # APN as a confirmed "Not live" mismatch.
    at_exec 'AT+CGDCONT?;+CGACT?;+CGPADDR'
    at_rc=$?
    if [ "$at_rc" -eq 1 ]; then
        at_exec 'AT+CGDCONT?;+CGACT?;+CGPADDR'
        at_rc=$?
    fi
    blob=$(printf '%s\n' "$AT_RAW" | tr -d '\r')
    if [ "$at_rc" -eq 1 ] || ! printf '%s\n' "$blob" | grep -q '^+CGDCONT:'; then
        die "at_failed" "Could not read modem PDP contexts"
    fi

    # --- Data CID (CGPADDR confirmed by the kernel route; see data_cid.sh) ---
    qm_detect_data_cid "$blob"

    # --- Stored slot-1 CID: display fallback when no bearer is up -----------
    config_json=$(read_config_v2)
    active_ptr=$(printf '%s' "$config_json" | jq -r '.active')
    case "$active_ptr" in ''|*[!0-9]*) active_ptr=0 ;; esac
    slot1_cid=$(printf '%s' "$config_json" | jq -r '
        .profiles[] | select(.id == 1) |
        if .cid == null then 1 else .cid end')
    case "$slot1_cid" in ''|*[!0-9]*) slot1_cid=1 ;; esac

    case "$QM_DATA_CID" in
        ''|*[!0-9]*) active_cid="$slot1_cid"; data_cid_known=0 ;;
        *)           active_cid="$QM_DATA_CID"; data_cid_known=1 ;;
    esac

    # --- Modem context table (cids[]): every CID 1..MAX_CID, tagged ---------
    # IMS/SOS contexts are kept and TAGGED via qm_apn_class so the UI can label
    # them. apn = live CGDCONT string ("" if undefined), is_internet = the
    # detected data CID (never true when no bearer is up), activated = CGACT
    # state (empty -> null when the modem did not report it). Streamed as TSV
    # (apn last; it may legitimately be empty) then assembled with jq.
    cids_tsv=""
    cid=1
    while [ "$cid" -le "$MAX_CID" ]; do
        row=$(printf '%s\n' "$QM_CID_ROWS" | grep "^$cid|" | head -1)
        live_apn=""
        activated=""
        if [ -n "$row" ]; then
            activated=$(printf '%s' "$row" | cut -d'|' -f2)
            live_apn=$(printf '%s' "$row" | cut -d'|' -f6-)
        fi
        apn_type=$(qm_apn_class "$live_apn")
        is_internet=0
        [ "$data_cid_known" = "1" ] && [ "$cid" = "$active_cid" ] && is_internet=1
        cids_tsv="${cids_tsv}${cid}	${apn_type}	${is_internet}	${activated}	${live_apn}
"
        cid=$((cid + 1))
    done

    cids_json=$(printf '%s' "$cids_tsv" | jq -Rsc '
        split("\n") | map(select(length > 0) | split("\t") | {
            cid:         (.[0] | tonumber),
            apn_type:    (if .[1] == null then "" else .[1] end),
            is_internet: (.[2] == "1"),
            activated:   (if .[3] == "1" then true elif .[3] == "0" then false else null end),
            apn:         (if .[4] == null then "" else .[4] end)
        })')
    [ -z "$cids_json" ] && die "parse_failed" "Could not assemble modem context list"

    # --- Slot-1 stored APN (the single user APN) ----------------------------
    # Slot 1's fields come from the config read above (normalize_v2 guarantees
    # all 5 slots exist). The `apn` object reflects whatever is stored, even
    # when active==0, so the form pre-fills with the last-saved value without
    # requiring a separate fetch.
    slot1_apn=$(printf '%s' "$config_json" | jq -r '
        .profiles[] | select(.id == 1) |
        if .apn == null then "" else .apn end')
    slot1_pdp=$(printf '%s' "$config_json" | jq -r '
        .profiles[] | select(.id == 1) |
        if .pdp_type == null then "ipv4v6" else .pdp_type end')

    apn_obj=$(jq -n \
        --arg apn "$slot1_apn" \
        --arg pdp_type "$slot1_pdp" \
        --argjson cid "$slot1_cid" \
        '{ apn: $apn, pdp_type: $pdp_type, cid: $cid }')
    [ -z "$apn_obj" ] && die "parse_failed" "Could not assemble stored APN object"

    qlog_info "APN settings: active=$active_ptr active_cid=$active_cid source=$QM_DATA_CID_SOURCE apn=$slot1_apn"

    jq -n \
        --argjson apn_obj "$apn_obj" \
        --argjson cids "$cids_json" \
        --argjson active_ptr "$active_ptr" \
        --argjson active_cid "$active_cid" \
        --arg data_cid_source "$QM_DATA_CID_SOURCE" \
        '{
            success: true,
            active: $active_ptr,
            active_cid: $active_cid,
            internet_cid: $active_cid,
            data_cid_source: $data_cid_source,
            apn: $apn_obj,
            cids: $cids
        }'
    exit 0
fi

# =============================================================================
# POST — {"action":"save"|"deactivate", ...}
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post
    ACTION=$(printf '%s' "$POST_DATA" | jq -r 'if .action == null then empty else .action end')

    # -----------------------------------------------------------------------
    # action: save — validate, write slot 1, always apply to modem, set active=1
    # -----------------------------------------------------------------------
    if [ "$ACTION" = "save" ]; then
        SLOT_CID=$(printf '%s' "$POST_DATA" | jq -r 'if .cid == null then "" else (.cid | tostring) end')
        APN=$(printf '%s' "$POST_DATA" | jq -r 'if .apn == null then "" else .apn end')
        PDP=$(printf '%s' "$POST_DATA" | jq -r 'if .pdp_type == null then "" else .pdp_type end')

        # --- Validate target cid (1..MAX_CID) ------------------------------
        case "$SLOT_CID" in
            ''|*[!0-9]*) die "invalid_cid" "cid must be an integer 1-${MAX_CID}" ;;
        esac
        if [ "$SLOT_CID" -lt 1 ] || [ "$SLOT_CID" -gt "$MAX_CID" ]; then
            die "invalid_cid" "cid must be 1-${MAX_CID}"
        fi

        # --- Validate apn + pdp_type ---------------------------------------
        [ -z "$APN" ] && die "missing_fields" "apn is required"
        # Strict allow-list: the value is spliced into AT+CGDCONT="...", so any
        # quote, CR/LF, ';' or ',' would let a direct POST inject AT commands.
        case "$APN" in
            *[!A-Za-z0-9._-]*) die "invalid_value" "APN may only contain letters, digits, '.', '-' and '_'" ;;
        esac
        [ "${#APN}" -gt 100 ] && die "invalid_value" "APN must be 100 characters or fewer"
        PDP_AT=$(pdp_to_at "$PDP")
        [ -z "$PDP_AT" ] && die "invalid_pdp_type" "pdp_type must be ipv4, ipv6, or ipv4v6"

        # --- Carrier-context guard (backend mirror of the UI confirm) --------
        # Overwriting an IMS/SOS-tagged context breaks VoLTE/emergency calls. The
        # UI confirms first and then sends allow_carrier_cid:true; a direct POST
        # without it is refused. Fails OPEN when the live read fails (as before).
        ALLOW_CARRIER=$(printf '%s' "$POST_DATA" | jq -r 'if .allow_carrier_cid == true then "1" else "0" end')
        if [ "$ALLOW_CARRIER" != "1" ]; then
            if at_exec 'AT+CGDCONT?' || [ $? -eq 2 ]; then
                guard_apn=$(printf '%s\n' "$AT_RAW" | tr -d '\r' | grep "^+CGDCONT: $SLOT_CID," | head -1 | awk -F'"' '{print $4}')
                if [ -n "$(qm_apn_class "$guard_apn")" ]; then
                    die "carrier_cid_protected" "CID $SLOT_CID holds a carrier-managed context"
                fi
            fi
        fi

        qlog_info "Save APN: apn=$APN pdp=$PDP_AT cid=$SLOT_CID"

        # --- Apply to the modem first (modem is the source of truth) --------
        # save always drives the COPS cycle — there is only one APN and it is
        # always meant to be live. Empty-APN slots are prevented by validation.
        apply_apn_to_modem "$SLOT_CID" "$PDP_AT" "$APN" || die "$APN_APPLY_ERR_CODE" "$APN_APPLY_ERR_DETAIL"

        # --- Persist slot 1 + set active=1 (best-effort after modem apply) --
        # If the modem write succeeded but the config write fails, still return
        # success: the modem is already live on the new APN. Emit a qlog_warn
        # so the issue is surfaced in the log; the hook's 1500ms reconcile
        # re-fetches live state. (Mirrors the existing activate action pattern.)
        config_json=$(read_config_v2)
        new_config=$(printf '%s' "$config_json" | jq -c \
            --arg apn "$APN" \
            --arg pdp "$PDP" \
            --argjson cid "$SLOT_CID" \
            '.profiles |= map(
                if .id == 1
                then { id: 1, name: "", apn: $apn, pdp_type: $pdp, cid: $cid }
                else . end
            ) | .active = 1' 2>/dev/null)
        if [ -n "$new_config" ] && write_config_v2 "$new_config"; then
            :
        else
            qlog_warn "Applied APN to modem but failed to persist slot 1 config"
        fi

        cgi_success
        exit 0
    fi

    # -----------------------------------------------------------------------
    # action: deactivate — revert the live modem to the carrier-default APN
    # (blank APN, carrier reassigns its default on re-attach) and set active=0.
    # No slot fields change; this is the deliberate inverse of save/activate.
    # -----------------------------------------------------------------------
    if [ "$ACTION" = "deactivate" ]; then
        config_json=$(read_config_v2)
        active_id=$(printf '%s' "$config_json" | jq -r '.active')

        # Already carrier-default: nothing to revert, do NOT touch the modem.
        if [ "$active_id" = "0" ]; then
            jq -n '{success: true, active: 0}'
            exit 0
        fi

        # --- Load the active slot's CID + PDP for the revert AT write -------
        SLOT_CID=$(printf '%s' "$config_json" | jq -r \
            --argjson id "$active_id" '.profiles[] | select(.id == $id) | .cid')
        SLOT_PDP=$(printf '%s' "$config_json" | jq -r \
            --argjson id "$active_id" '.profiles[] | select(.id == $id) | .pdp_type')

        PDP_AT=$(pdp_to_at "$SLOT_PDP")
        [ -z "$PDP_AT" ] && PDP_AT="IPV4V6"
        # Active config is normalized, but guard the CID before driving AT.
        case "$SLOT_CID" in
            ''|*[!0-9]*) SLOT_CID=1 ;;
        esac

        qlog_info "Deactivate: reverting slot $active_id (cid=$SLOT_CID) to carrier default; active=0"

        # --- Drive the modem first; empty APN -> carrier reassigns default --
        apply_apn_to_modem "$SLOT_CID" "$PDP_AT" "" || die "$APN_APPLY_ERR_CODE" "$APN_APPLY_ERR_DETAIL"

        # --- Persist active=0. A persist failure AFTER a successful modem
        # revert still reports success: the modem is already on carrier-default,
        # so failing the request would mislead the UI. Warn only.
        new_config=$(printf '%s' "$config_json" | jq -c '.active = 0' 2>/dev/null)
        if [ -n "$new_config" ] && write_config_v2 "$new_config"; then
            :
        else
            qlog_warn "Reverted slot $active_id on modem but failed to persist active=0"
        fi

        jq -n '{success: true, active: 0}'
        exit 0
    fi

    die "invalid_action" "action must be save or deactivate"
fi

# --- Method not allowed -------------------------------------------------------
cgi_method_not_allowed
