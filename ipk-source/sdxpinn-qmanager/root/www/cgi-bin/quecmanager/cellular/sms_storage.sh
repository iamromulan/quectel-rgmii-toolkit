#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# sms_storage.sh — CGI Endpoint: where incoming SMS are stored (GET + POST)
# =============================================================================
# GET:  {"success":true,"storage":"ME"|"SM","routing":"ME"|"SM"|"",
#        "storages":[{"storage":"ME","used":N,"total":N},{"storage":"SM",...}],
#        "storage_errors":{"SM":"..."}?}
#       storage = the saved choice, routing = the modem's live mem3 ("" if the
#       read failed). A storage whose status read fails is left out of
#       storages and named in storage_errors.
# POST: {"storage":"ME"|"SM"} -> save the choice, apply it, read it back.
#       Errors: invalid_storage, sim_storage_unavailable, save_failed,
#       apply_failed (the previous choice is put back), modem_busy.
#
# The choice lives in /etc/qmanager/sms_storage ("ME" or "SM"; missing = ME).
# qmanager_atd reads it after every SMS operation and restores
# AT+CPMS="X","X","X", and qmanager_sms_storage applies it at boot. Changing it
# does not move existing messages: the inbox keeps reading both storages.
#
# Endpoint: GET/POST /cgi-bin/quecmanager/cellular/sms_storage.sh
# Install location: /www/cgi-bin/quecmanager/cellular/sms_storage.sh
# =============================================================================

qlog_init "cgi_sms_storage"
cgi_headers
cgi_handle_options

PREF_FILE="/etc/qmanager/sms_storage"
QSMS="/usr/bin/qsms"
QCMD="/usr/bin/qcmd"

[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

# Saved choice: "SM" only when the file says so, else "ME".
_ss_pref() {
    _ss_p=$(tr -d ' \r\n' < "$PREF_FILE" 2>/dev/null | tr 'a-z' 'A-Z')
    [ "$_ss_p" = "SM" ] && printf 'SM' || printf 'ME'
}

# Live incoming-message storage (mem3) from AT+CPMS?, or "" on failure.
_ss_routing() {
    _ss_line=$("$QCMD" 'AT+CPMS?' 2>/dev/null | tr -d '\r' | grep '^+CPMS:' | head -n1)
    [ -n "$_ss_line" ] || return 0
    printf '%s' "$_ss_line" | sed 's/^+CPMS: *//' | cut -d, -f7 | tr -d '" '
}

# Point all three CPMS pointers at $1. rc 0 only on an OK final line.
_ss_apply() {
    _ss_out=$("$QCMD" "AT+CPMS=\"$1\",\"$1\",\"$1\"" 2>/dev/null)
    _ss_rc=$?
    [ "$_ss_rc" -eq 0 ] && printf '%s\n' "$_ss_out" | tr -d '\r' | grep -q '^OK'
}

_ss_write_pref() {
    if command -v qm_atomic_write >/dev/null 2>&1; then
        printf '%s\n' "$1" | qm_atomic_write "$PREF_FILE" 0644
    else
        printf '%s\n' "$1" > "$PREF_FILE"
    fi
}

# =============================================================================
# GET
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    pref=$(_ss_pref)

    status_json=$("$QSMS" status all 2>/dev/null)
    storages=$(printf '%s' "$status_json" | jq -c 'if (.storages | type) == "array" then .storages else empty end' 2>/dev/null)
    storage_errors="{}"
    if [ -z "$storages" ]; then
        # The combined read fails as a whole when one store is unusable
        # (typically the SIM), so read each one on its own.
        storages="[]"
        for m in ME SM; do
            one=$("$QSMS" status "$m" 2>/dev/null)
            if printf '%s' "$one" | jq -e '.success == true' >/dev/null 2>&1; then
                storages=$(printf '%s' "$storages" | jq -c --argjson o "$one" '. + [{storage: $o.storage, used: $o.used, total: $o.total}]')
            else
                err=$(printf '%s' "$one" | jq -r 'if .detail == null or .detail == "" then (if .error == null then "unavailable" else .error end) else .detail end' 2>/dev/null)
                storage_errors=$(printf '%s' "$storage_errors" | jq -c --arg m "$m" --arg e "${err:-unavailable}" '. + {($m): $e}')
            fi
        done
    fi

    routing=$(_ss_routing)
    case "$routing" in ME|SM) ;; *) routing="" ;; esac

    jq -n --arg storage "$pref" --arg routing "$routing" \
        --argjson storages "$storages" --argjson errs "$storage_errors" \
        '{success: true, storage: $storage, routing: $routing, storages: $storages}
         + (if ($errs | length) > 0 then {storage_errors: $errs} else {} end)'
    exit 0
fi

# =============================================================================
# POST
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post

    want=$(printf '%s' "$POST_DATA" | jq -r 'if .storage == null then empty else (.storage | tostring) end' 2>/dev/null)
    case "$want" in
        ME|SM) ;;
        *)
            cgi_error "invalid_storage" "storage must be ME or SM"
            exit 0
            ;;
    esac

    prev=$(_ss_pref)

    # Refuse SIM storage the modem cannot use (no SIM, or a SIM without an
    # SMS store), before anything is saved.
    if [ "$want" = "SM" ]; then
        chk=$("$QSMS" status SM 2>/dev/null)
        if ! printf '%s' "$chk" | jq -e '.success == true' >/dev/null 2>&1; then
            code=$(printf '%s' "$chk" | jq -r 'if .error == null then "" else .error end' 2>/dev/null)
            if [ "$code" = "modem_busy" ]; then
                cgi_error "modem_busy" "Could not acquire AT lock"
            else
                qlog_warn "SIM storage unusable: $(printf '%s' "$chk" | jq -r 'if .detail == null then "" else .detail end' 2>/dev/null)"
                cgi_error "sim_storage_unavailable" "The SIM has no usable message storage"
            fi
            exit 0
        fi
    fi

    if ! _ss_write_pref "$want"; then
        cgi_error "save_failed" "Could not save the storage choice"
        exit 0
    fi

    if _ss_apply "$want" && [ "$(_ss_routing)" = "$want" ]; then
        qlog_info "SMS storage set to $want (was $prev)"
        jq -n --arg storage "$want" '{success: true, storage: $storage}'
        exit 0
    fi

    # Put the previous choice back so the file and the modem agree.
    _ss_write_pref "$prev"
    _ss_apply "$prev"
    qlog_error "Failed to apply SMS storage $want; restored $prev"
    cgi_error "apply_failed" "The modem did not accept the storage change"
    exit 0
fi

cgi_method_not_allowed
