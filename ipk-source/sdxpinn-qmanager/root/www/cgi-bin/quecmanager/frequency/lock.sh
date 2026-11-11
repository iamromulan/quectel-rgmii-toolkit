#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# lock.sh — CGI Endpoint: Apply/Clear Frequency Lock
# =============================================================================
# Handles frequency lock and unlock operations for both LTE and NR5G.
# Checks tower lock mutual exclusion before applying frequency locks.
#
# NOTE: The NR5G earfcn_lock command cannot coexist with AT+QNWLOCK="common/5g".
# NOTE: LTE earfcn_lock on unsupported bands may cause modem crash dump.
#
# POST body examples:
#   LTE lock:   {"type":"lte","action":"lock","earfcns":[1300,3400]}
#   LTE unlock: {"type":"lte","action":"unlock"}
#   NR lock:    {"type":"nr","action":"lock","entries":[{"arfcn":504990,"scs":30}]}
#   NR unlock:  {"type":"nr","action":"unlock"}
#
# Endpoint: POST /cgi-bin/quecmanager/frequency/lock.sh
# Install location: /www/cgi-bin/quecmanager/frequency/lock.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_freq_lock"
cgi_headers
cgi_handle_options

# --- Load tower lock library (for tower_read_lte_lock / tower_read_nr_lock) --
if [ -f /usr/lib/qmanager/tower_lock_mgr.sh ]; then
    . /usr/lib/qmanager/tower_lock_mgr.sh
else
    cgi_error "internal_error" "tower lock library unavailable"
    exit 0
fi

# --- Tower lock gate read (fail closed) --------------------------------------
# Prints the tower lock state for one leg, or the literal "error" when it could
# not be confirmed. Stacking a frequency lock on a live tower lock can
# crash-dump the modem, so an unread state must never pass the gate as
# "unlocked". The readers print "error" and return 1 on a failed AT read; the
# empty / rc arms also cover a reader that never ran at all. One retry absorbs
# a transient hiccup before the caller refuses.
# Usage: state=$(freq_read_tower_state tower_read_lte_lock)
freq_read_tower_state() {
    _fts_state=$("$1" 2>/dev/null)
    _fts_rc=$?
    if [ "$_fts_rc" -ne 0 ] || [ -z "$_fts_state" ] || [ "$_fts_state" = "error" ]; then
        sleep 0.1
        _fts_state=$("$1" 2>/dev/null)
        _fts_rc=$?
    fi
    if [ "$_fts_rc" -ne 0 ] || [ -z "$_fts_state" ]; then
        _fts_state="error"
    fi
    printf '%s' "$_fts_state"
}

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Read POST body ----------------------------------------------------------
cgi_read_post

# --- Parse common fields ----------------------------------------------------
LOCK_TYPE=$(printf '%s' "$POST_DATA" | jq -r '.type // empty' 2>/dev/null)
ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty' 2>/dev/null)

if [ -z "$LOCK_TYPE" ]; then
    cgi_error "no_type" "Missing type field (lte or nr)"
    exit 0
fi

if [ -z "$ACTION" ]; then
    cgi_error "no_action" "Missing action field (lock or unlock)"
    exit 0
fi

# =============================================================================
# LTE Frequency Lock/Unlock
# =============================================================================
if [ "$LOCK_TYPE" = "lte" ]; then

    if [ "$ACTION" = "lock" ]; then
        # --- Check tower lock mutual exclusion ---
        lte_tower_state=$(freq_read_tower_state tower_read_lte_lock)
        case "$lte_tower_state" in
            locked*)
                cgi_error "tower_lock_active" "Cannot use frequency lock while LTE tower lock is active. Disable tower lock first."
                exit 0
                ;;
            error)
                cgi_error "tower_lock_unknown" "Could not verify LTE tower lock state, refusing frequency lock. Try again."
                exit 0
                ;;
        esac

        # --- Parse earfcns array ---
        earfcn_count=$(printf '%s' "$POST_DATA" | jq -r '.earfcns | length' 2>/dev/null)

        if [ -z "$earfcn_count" ] || [ "$earfcn_count" -lt 1 ] 2>/dev/null || [ "$earfcn_count" -gt 2 ] 2>/dev/null; then
            cgi_error "invalid_count" "LTE frequency lock requires 1-2 EARFCNs"
            exit 0
        fi

        # Build colon-separated EARFCN list and validate
        earfcn_list=""
        i=0
        while [ "$i" -lt "$earfcn_count" ]; do
            val=$(printf '%s' "$POST_DATA" | jq -r "(.earfcns[$i]) | if . == null then empty else tostring end" 2>/dev/null)

            # Validate numeric
            case "$val" in
                ''|*[!0-9]*)
                    cgi_error "invalid_earfcn" "EARFCN must be a positive integer"
                    exit 0
                    ;;
            esac

            if [ -z "$earfcn_list" ]; then
                earfcn_list="$val"
            else
                earfcn_list="${earfcn_list}:${val}"
            fi
            i=$((i + 1))
        done

        qlog_info "LTE freq lock: $earfcn_count EARFCN(s) — $earfcn_list"

        # Send AT command
        result=$(qcmd "AT+QNWCFG=\"lte_earfcn_lock\",$earfcn_count,$earfcn_list" 2>/dev/null)
        rc=$?

        if [ $rc -ne 0 ] || [ -z "$result" ]; then
            qlog_error "LTE freq lock failed (rc=$rc)"
            cgi_error "modem_error" "Failed to send LTE frequency lock command"
            exit 0
        fi

        case "$result" in
            *ERROR*)
                qlog_error "LTE freq lock AT ERROR: $result"
                cgi_error "at_error" "Modem rejected LTE frequency lock command"
                exit 0
                ;;
        esac

        qlog_info "LTE freq lock applied successfully"
        jq -n --argjson count "$earfcn_count" \
            '{"success":true,"type":"lte","action":"lock","count":$count}'

    elif [ "$ACTION" = "unlock" ]; then
        result=$(qcmd 'AT+QNWCFG="lte_earfcn_lock",0' 2>/dev/null)
        rc=$?

        if [ $rc -ne 0 ] || [ -z "$result" ]; then
            qlog_error "LTE freq unlock failed (rc=$rc)"
            cgi_error "modem_error" "Failed to clear LTE frequency lock"
            exit 0
        fi

        case "$result" in
            *ERROR*)
                qlog_error "LTE freq unlock AT ERROR: $result"
                cgi_error "at_error" "Modem rejected LTE frequency unlock command"
                exit 0
                ;;
        esac

        qlog_info "LTE freq lock cleared"
        jq -n '{"success":true,"type":"lte","action":"unlock"}'
    else
        cgi_error "invalid_action" "action must be lock or unlock"
        exit 0
    fi

# =============================================================================
# NR5G Frequency Lock/Unlock
# =============================================================================
elif [ "$LOCK_TYPE" = "nr" ]; then

    if [ "$ACTION" = "lock" ]; then
        # --- Check tower lock mutual exclusion ---
        nr_tower_state=$(freq_read_tower_state tower_read_nr_lock)
        case "$nr_tower_state" in
            locked*)
                cgi_error "tower_lock_active" "Cannot use frequency lock while NR tower lock is active. This command cannot be used together with AT+QNWLOCK common/5g."
                exit 0
                ;;
            error)
                cgi_error "tower_lock_unknown" "Could not verify NR tower lock state, refusing frequency lock. Try again."
                exit 0
                ;;
        esac

        # --- Parse entries array ---
        nr_count=$(printf '%s' "$POST_DATA" | jq -r '.entries | length' 2>/dev/null)

        if [ -z "$nr_count" ] || [ "$nr_count" -lt 1 ] 2>/dev/null || [ "$nr_count" -gt 32 ] 2>/dev/null; then
            cgi_error "invalid_count" "NR frequency lock requires 1-32 entries"
            exit 0
        fi

        # Build colon-separated EARFCN:SCS pairs and validate
        arfcn_list=""
        i=0
        while [ "$i" -lt "$nr_count" ]; do
            arfcn=$(printf '%s' "$POST_DATA" | jq -r "(.entries[$i].arfcn) | if . == null then empty else tostring end" 2>/dev/null)
            scs=$(printf '%s' "$POST_DATA" | jq -r "(.entries[$i].scs) | if . == null then empty else tostring end" 2>/dev/null)

            # Validate ARFCN is numeric
            case "$arfcn" in
                ''|*[!0-9]*)
                    cgi_error "invalid_arfcn" "NR-ARFCN must be a positive integer"
                    exit 0
                    ;;
            esac

            # Validate SCS value
            case "$scs" in
                15|30|60|120|240) ;;
                *)
                    cgi_error "invalid_scs" "SCS must be 15, 30, 60, 120, or 240 kHz"
                    exit 0
                    ;;
            esac

            if [ -z "$arfcn_list" ]; then
                arfcn_list="${arfcn}:${scs}"
            else
                arfcn_list="${arfcn_list}:${arfcn}:${scs}"
            fi
            i=$((i + 1))
        done

        qlog_info "NR freq lock: $nr_count entry/entries — $arfcn_list"

        # Send AT command
        result=$(qcmd "AT+QNWCFG=\"nr5g_earfcn_lock\",$nr_count,$arfcn_list" 2>/dev/null)
        rc=$?

        if [ $rc -ne 0 ] || [ -z "$result" ]; then
            qlog_error "NR freq lock failed (rc=$rc)"
            cgi_error "modem_error" "Failed to send NR frequency lock command"
            exit 0
        fi

        case "$result" in
            *ERROR*)
                qlog_error "NR freq lock AT ERROR: $result"
                cgi_error "at_error" "Modem rejected NR frequency lock command"
                exit 0
                ;;
        esac

        qlog_info "NR freq lock applied successfully"
        jq -n --argjson count "$nr_count" \
            '{"success":true,"type":"nr","action":"lock","count":$count}'

    elif [ "$ACTION" = "unlock" ]; then
        result=$(qcmd 'AT+QNWCFG="nr5g_earfcn_lock",0' 2>/dev/null)
        rc=$?

        if [ $rc -ne 0 ] || [ -z "$result" ]; then
            qlog_error "NR freq unlock failed (rc=$rc)"
            cgi_error "modem_error" "Failed to clear NR frequency lock"
            exit 0
        fi

        case "$result" in
            *ERROR*)
                qlog_error "NR freq unlock AT ERROR: $result"
                cgi_error "at_error" "Modem rejected NR frequency unlock command"
                exit 0
                ;;
        esac

        qlog_info "NR freq lock cleared"
        jq -n '{"success":true,"type":"nr","action":"unlock"}'
    else
        cgi_error "invalid_action" "action must be lock or unlock"
        exit 0
    fi

else
    cgi_error "invalid_type" "type must be lte or nr"
    exit 0
fi
