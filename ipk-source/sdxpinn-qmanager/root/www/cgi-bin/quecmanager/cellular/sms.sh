#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# sms.sh — CGI Endpoint: SMS conversations (GET + POST), storage-aware
# =============================================================================
# GET:              inbox: {success, messages[], threads[], storage:{used,total},
#                   smsc:{addr,status,time}|null, unread_total:0}
# GET ?addr=<a>     one thread, oldest-first: {success, addr, count, messages[],
#                   has_more:false} (&before= is accepted and ignored)
# GET ?action=smsc  {success, smsc:{addr,status,time}} | modem_busy |
#                   smsc_read_failed
#
# Messages are the received ones on the modem (ME + SM, multi-part merged)
# plus QManager's own sent log (sms_sent.sh, storage "SENT"). Read state is
# client-side: AT+CMGL=4 marks everything read on every list, so the backend
# never reports unread.
#
# STORAGE ROUTING:
#   The modem routes incoming SMS by CPMS mem3. qsms (the SMS client of the
#   qmanager_atd broker) selects each storage per operation and ALWAYS
#   restores the user's chosen storage afterwards (ME by default, SM via
#   cellular/sms_storage.sh). We read BOTH ME and SM, tag each message with
#   its storage, and merge so messages on either store stay visible and
#   individually deletable. qmanager_sms_storage sets the routing at boot.
#
# Transport (/usr/bin/qsms -> qmanager_atd; one JSON line on stdout, rc 0/1):
#   qsms list all                 -> {"success":true,"msg":[{index,storage,...}]}
#   qsms status all               -> {"success":true,"storages":[{storage,used,total}]}
#   qsms send <phone> <msg>       -> {"success":true,"parts":N,"refs":[...]}
#   qsms delete <ME|SM> <i,j,..>  -> {"success":..,"deleted":[..],"failed":[..]}
#   qsms delete <ME|SM> all       -> {"success":..,"deleted":N,"remaining":0}
#   Failure: {"success":false,"error":<code>[,"detail":...]}
#   The broker takes /var/lock/qmanager.lock itself: never wrap qsms (or
#   qcmd) in flock on that lock (the broker would wait on us until modem_busy).
#
# POST body: { "action": ..., ... }
#   send       {phone, message}            also logged as sent (or failed)
#   delete     {indexes:[..], storage:"ME"|"SM"}
#   delete     {storage:"SENT", identities:["S<seq>:<time>", ..]}
#   delete     {addr, index:"ALL"}         every modem message from addr +
#                                          the sent records to addr
#   delete_all {}                          ME + SM + the sent log
#   set_smsc   {addr}                      AT+CSCA write, read back
#
# Endpoint: GET/POST /cgi-bin/quecmanager/cellular/sms.sh
# Install location: /www/cgi-bin/quecmanager/cellular/sms.sh
# =============================================================================

qlog_init "cgi_sms"
cgi_headers
cgi_handle_options

QCMD="/usr/bin/qcmd"

if [ -f /usr/lib/qmanager/sms_sent.sh ]; then
    . /usr/lib/qmanager/sms_sent.sh
else
    sms_sent_read() { printf '[]\n'; }
    sms_sent_append() { return 1; }
    sms_sent_delete_identities() { return 1; }
    sms_sent_delete_addr() { return 1; }
    sms_sent_clear() { return 0; }
fi

# --- qsms wrapper ------------------------------------------------------------
# stdout is the JSON envelope (also on failure); stderr is dropped.
_sms_q() {
    /usr/bin/qsms "$@" 2>/dev/null
}

# Echo the envelope's error code ("" when absent / not JSON).
_sms_err_code() {
    printf '%s' "$1" | jq -r 'if .error == null then empty else .error end' 2>/dev/null
}

# Echo a human detail for a failed envelope: detail, else the code, else $2.
_sms_err_detail() {
    _d=$(printf '%s' "$1" | jq -r 'if .detail != null then (.detail | tostring) elif .error != null then (.error | tostring) else empty end' 2>/dev/null)
    [ -n "$_d" ] || _d="$2"
    printf '%s' "$_d"
}

# True when a failure means "another AT user holds the modem". Reported as
# modem_busy, exactly like the old lock timeout.
_sms_is_busy() {
    case "$1" in
        modem_busy|scan_in_progress) return 0 ;;
    esac
    return 1
}

_sms_busy_reply() {
    jq -n '{"success":false,"error":"modem_busy","detail":"Could not acquire AT lock"}'
}

# --- Query string ------------------------------------------------------------
# _sms_qs <name> — raw (still encoded) value of a query parameter, "" if absent.
_sms_qs() {
    _qs="&$QUERY_STRING"
    case "$_qs" in
        *"&$1="*)
            _qv="${_qs#*&"$1"=}"
            printf '%s' "${_qv%%&*}"
            ;;
    esac
}

# _sms_urldecode <s> — application/x-www-form-urlencoded decode ("+" is a
# space, %XX a byte). BusyBox awk's %c emits the raw byte, so UTF-8 survives.
# A malformed escape stays literal; %00 is dropped.
_sms_urldecode() {
    _SMS_UD="$1" awk 'BEGIN {
        s = ENVIRON["_SMS_UD"]; hex = "0123456789abcdef"; n = length(s)
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (c == "+") { printf " "; continue }
            if (c == "%" && i + 2 <= n) {
                a = index(hex, tolower(substr(s, i + 1, 1)))
                b = index(hex, tolower(substr(s, i + 2, 1)))
                if (a && b) {
                    v = (a - 1) * 16 + (b - 1)
                    if (v > 0) printf "%c", v
                    i += 2
                    continue
                }
            }
            printf "%s", c
        }
    }'
}

# --- Device UTC offset (seconds east of UTC) ----------------------------------
# qsms timestamps are device-local wall clock without a zone.
_sms_utc_offset() {
    _off=$(date +%z 2>/dev/null | awk '{
        s = substr($0, 1, 1); h = substr($0, 2, 2) + 0; m = substr($0, 4, 2) + 0
        o = h * 3600 + m * 60; if (s == "-") o = -o; print o }')
    case "$_off" in
        ''|-|*[!0-9-]*) _off=0 ;;
    esac
    printf '%s' "$_off"
}

# --- SMSC ---------------------------------------------------------------------
# _sms_smsc_read — sets SMSC_ADDR. rc 0 ok, 1 read failed, 2 modem busy.
_sms_smsc_read() {
    SMSC_ADDR=""
    _sc_out=$("$QCMD" 'AT+CSCA?' 2>&1)
    _sc_rc=$?
    if [ "$_sc_rc" -ne 0 ]; then
        case "$_sc_out" in
            *modem_busy*|*scan_in_progress*) return 2 ;;
        esac
        return 1
    fi
    _sc_line=$(printf '%s\n' "$_sc_out" | tr -d '\r' | grep '^+CSCA:' | head -n1)
    [ -n "$_sc_line" ] || return 1
    SMSC_ADDR=$(printf '%s' "$_sc_line" | sed -n 's/^+CSCA: *"\([^"]*\)".*/\1/p')
    [ -n "$SMSC_ADDR" ] || return 1
    return 0
}

_sms_smsc_json() {
    jq -cn --arg addr "$1" '{addr: $addr, status: "", time: ""}'
}

# --- Message model -------------------------------------------------------------
# jq program run over a slurped stream: .[0] raw qsms messages, .[1] the sent
# log, .[2] the smsc object or null. Defines $all (merged, newest-first).
# $off = device UTC offset seconds.
SMS_JQ_MODEL='
def tsort: .[6:8] + .[0:2] + .[3:5] + .[8:];
def epoch: (try (("20" + .[6:8] + "-" + .[0:2] + "-" + .[3:5] + "T" + .[9:17] + "Z")
             | fromdateiso8601) catch null) as $e | if $e == null then 0 else $e - $off end;
def kind:
  (explode) as $c
  | if any($c[]; (. >= 65 and . <= 90) or (. >= 97 and . <= 122) or . >= 128)
    then "alphanumeric"
    else (ltrimstr("+") | explode) as $d
      | if ($d | length) > 0 and ($d | length) <= 6 and all($d[]; . >= 48 and . <= 57)
        then "shortcode" else "msisdn" end
    end;
def who: ((.addr // "") | kind) as $k
  | . + {display_name: .addr, addr_kind: $k,
         display_source: (if $k == "alphanumeric" then "network" else "raw" end)};

(.[0]) as $raw | (.[1]) as $sent |
(
  ([$raw[] | select(has("reference") | not) |
     {indexes: [.index], sender, content, timestamp, storage}]
  ) +
  ([$raw[] | select(has("reference"))] |
     group_by(.sender + "|" + (.reference | tostring) + "|" + .storage + "|" + ((.total // 0) | tostring)) |
     [.[]
      | sort_by((.timestamp | tsort), .index)
      | reduce .[] as $p ([];
          if length > 0 and ((.[-1] | any(.[]; .part == $p.part)) | not)
          then .[:-1] + [.[-1] + [$p]]
          else . + [[$p]] end)
      | .[] | sort_by(.part) | {
         indexes: [.[].index],
         sender: .[0].sender,
         content: ([.[].content] | join("")),
         timestamp: .[0].timestamp,
         storage: .[0].storage
     }])
  | map((.timestamp | epoch) as $t
        | . + {addr: (.sender // ""), index: .indexes[0], time: $t,
               direction: "inbound", type: 1, status: "success", result: 1,
               identity: (.storage + (.indexes[0] | tostring) + ":" + ($t | tostring))}
        | who)
) as $inbound |
($sent | map(select(.addr != null and .seq != null) |
    ((.time // 0) | tonumber? // 0) as $t
    | (if .status == "failed" then "failed" else "success" end) as $st
    | {indexes: [], index: null, sender: .addr, addr: .addr,
       content: (.content // ""), storage: "SENT",
       timestamp: (($t + $off) | strftime("%m/%d/%y %H:%M:%S")),
       time: $t, seq: .seq,
       direction: "outbound", type: 0, status: $st,
       result: (if $st == "success" then 1 else 0 end),
       identity: ("S" + (.seq | tostring) + ":" + ($t | tostring))}
    | who)
) as $outbound |
(($inbound + $outbound) | sort_by(.time, (.timestamp | tsort)) | reverse) as $all
'

# _sms_model_input <smsc_json|null> — the model input stream for jq -s; the
# raw qsms messages come from $raw_msgs.
_sms_model_input() {
    printf '%s\n' "$raw_msgs"
    sms_sent_read
    printf '%s\n' "$1"
}

# _sms_read_raw — fill raw_msgs from qsms list all. On failure, writes the
# error reply and returns 1.
_sms_read_raw() {
    list_json=$(_sms_q list all)
    list_rc=$?
    if [ "$list_rc" -ne 0 ]; then
        code=$(_sms_err_code "$list_json")
        if _sms_is_busy "$code"; then
            qlog_error "SMS list: modem busy ($code)"
            _sms_busy_reply
            return 1
        fi
        detail=$(_sms_err_detail "$list_json" "qsms list failed (rc=$list_rc)")
        qlog_error "SMS list failed: $detail"
        jq -n --arg error "${code:-command_failed}" --arg detail "$detail" \
            '{"success":false,"error":$error,"detail":$detail}'
        return 1
    fi
    list_errs=$(printf '%s' "$list_json" | jq -c 'if .storage_errors == null then empty else .storage_errors end' 2>/dev/null)
    [ -n "$list_errs" ] && qlog_warn "SMS list storage errors: $list_errs"

    raw_msgs=$(printf '%s' "$list_json" | jq -c 'if (.msg | type) == "array" then .msg else [] end' 2>/dev/null)
    [ -n "$raw_msgs" ] || raw_msgs="[]"
    return 0
}

# _sms_reply <json> — print a built reply, or an error envelope if the model
# produced nothing.
_sms_reply() {
    if [ -n "$1" ]; then
        printf '%s\n' "$1"
    else
        qlog_error "SMS model build failed"
        cgi_error "command_failed" "Could not build the message list"
    fi
}

# =============================================================================
# GET
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    REQ_ACTION=$(_sms_qs action)

    # --- ?action=smsc ----------------------------------------------------------
    if [ "$REQ_ACTION" = "smsc" ]; then
        _sms_smsc_read
        case $? in
            0) jq -n --argjson smsc "$(_sms_smsc_json "$SMSC_ADDR")" '{success: true, smsc: $smsc}' ;;
            2) _sms_busy_reply ;;
            *) cgi_error "smsc_read_failed" "Could not read the SMS centre number" ;;
        esac
        exit 0
    fi

    off=$(_sms_utc_offset)

    # --- ?addr=<addr> — one thread ---------------------------------------------
    case "&$QUERY_STRING" in
        *"&addr="*)
            ADDR=$(_sms_urldecode "$(_sms_qs addr)")
            if [ -z "$ADDR" ]; then
                cgi_error "missing_addr" "addr is required"
                exit 0
            fi
            _sms_read_raw || exit 0
            reply=$(_sms_model_input null | jq -s --argjson off "$off" --arg addr "$ADDR" \
                "$SMS_JQ_MODEL"'
                | [$all[] | select(.addr == $addr)] | reverse
                | {success: true, addr: $addr, count: length, messages: ., has_more: false}' 2>/dev/null)
            _sms_reply "$reply"
            exit 0
            ;;
    esac

    # --- Inbox ---------------------------------------------------------------
    qlog_info "Fetching SMS inbox and status (ME + SM + sent)"
    _sms_read_raw || exit 0

    # Combined storage status: sum used and total across ME + SM. If the
    # combined query fails (e.g. no usable SIM store), fall back to ME alone.
    if status_json=$(_sms_q status all); then
        storage_used=$(printf '%s' "$status_json" | jq '[.storages[]?.used // 0] | add // 0' 2>/dev/null)
        storage_total=$(printf '%s' "$status_json" | jq '[.storages[]?.total // 0] | add // 0' 2>/dev/null)
    else
        status_json=$(_sms_q status ME)
        storage_used=$(printf '%s' "$status_json" | jq '.used // 0' 2>/dev/null)
        storage_total=$(printf '%s' "$status_json" | jq '.total // 0' 2>/dev/null)
    fi
    case "$storage_used" in ''|*[!0-9]*) storage_used=0 ;; esac
    case "$storage_total" in ''|*[!0-9]*) storage_total=0 ;; esac

    # SMSC is decoration: a busy or failed read is smsc:null, never an error.
    smsc_json=null
    if _sms_smsc_read; then
        smsc_json=$(_sms_smsc_json "$SMSC_ADDR")
    fi

    reply=$(_sms_model_input "$smsc_json" | jq -s --argjson off "$off" \
        --argjson used "$storage_used" --argjson total "$storage_total" \
        "$SMS_JQ_MODEL"'
        | (.[2]) as $smsc
        | {
            success: true,
            messages: $all,
            threads: ($all | group_by(.addr) | map(max_by(.time) as $l | {
                addr: $l.addr, sender: $l.addr,
                display_name: $l.display_name, display_source: $l.display_source,
                addr_kind: $l.addr_kind,
                latestMessage: $l.content, content: $l.content,
                timestamp: $l.timestamp, timestampSec: $l.time,
                unreadCount: 0, latestIndex: ($l.index // 0),
                direction: $l.direction, type: $l.type, status: $l.status
              }) | sort_by(.timestampSec) | reverse),
            storage: {used: $used, total: $total},
            smsc: $smsc,
            unread_total: 0
          }' 2>/dev/null)
    _sms_reply "$reply"
    exit 0
fi

# =============================================================================
# POST
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r 'if .action == null then empty else .action end' 2>/dev/null)

    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    # --- action: send --------------------------------------------------------
    if [ "$ACTION" = "send" ]; then
        RAW_PHONE=$(printf '%s' "$POST_DATA" | jq -r 'if .phone == null then empty else (.phone | tostring) end' 2>/dev/null)
        MESSAGE=$(printf '%s' "$POST_DATA" | jq -r 'if .message == null then empty else (.message | tostring) end' 2>/dev/null)

        if [ -z "$RAW_PHONE" ]; then
            cgi_error "missing_phone" "phone number is required"
            exit 0
        fi
        if [ -z "$MESSAGE" ]; then
            cgi_error "missing_message" "message text is required"
            exit 0
        fi

        # Only normalization: strip a leading + if present. The user is
        # responsible for providing the full international number. The sent
        # log keeps the number as given so it threads with the same addr.
        PHONE=$(printf '%s' "$RAW_PHONE" | sed 's/^+//')

        qlog_info "Sending SMS to $PHONE (raw: $RAW_PHONE)"
        result=$(_sms_q send "$PHONE" "$MESSAGE")
        rc=$?

        if [ $rc -ne 0 ]; then
            sms_sent_append "$RAW_PHONE" "$MESSAGE" failed \
                || qlog_warn "SMS send: could not log the failed message"
            code=$(_sms_err_code "$result")
            if _sms_is_busy "$code"; then
                qlog_error "SMS send: modem busy ($code)"
                _sms_busy_reply
                exit 0
            fi
            detail=$(_sms_err_detail "$result" "qsms send failed (rc=$rc)")
            qlog_error "SMS send failed (${code:-rc=$rc}): $detail"
            jq -n --arg detail "$detail" \
                '{"success":false,"error":"send_failed","detail":$detail}'
            exit 0
        fi

        sms_sent_append "$RAW_PHONE" "$MESSAGE" success \
            || qlog_warn "SMS send: sent, but could not log the message"
        qlog_info "SMS sent successfully to $PHONE"
        cgi_success
        exit 0
    fi

    # --- action: delete ------------------------------------------------------
    if [ "$ACTION" = "delete" ]; then
        STORAGE=$(printf '%s' "$POST_DATA" | jq -r 'if .storage == null then "ME" else (.storage | tostring) end' 2>/dev/null)
        DEL_ADDR=$(printf '%s' "$POST_DATA" | jq -r 'if .addr == null then empty else (.addr | tostring) end' 2>/dev/null)
        DEL_INDEX=$(printf '%s' "$POST_DATA" | jq -r 'if .index == null then empty else (.index | tostring) end' 2>/dev/null)

        # --- sent-log records ---------------------------------------------------
        if [ "$STORAGE" = "SENT" ]; then
            IDS=$(printf '%s' "$POST_DATA" | jq -c 'if (.identities | type) == "array" and (.identities | length) > 0 and all(.identities[]; type == "string") then .identities else empty end' 2>/dev/null)
            if [ -z "$IDS" ]; then
                cgi_error "missing_identities" "identities array is required"
                exit 0
            fi
            if sms_sent_delete_identities "$IDS"; then
                qlog_info "Deleted sent SMS records: $IDS"
                cgi_success
            else
                qlog_error "Could not update the sent SMS log"
                cgi_error "partial_failure" "sent messages could not be deleted"
            fi
            exit 0
        fi

        # --- a whole conversation -----------------------------------------------
        if [ -n "$DEL_ADDR" ] && [ "$DEL_INDEX" = "ALL" ]; then
            qlog_info "Deleting SMS conversation with $DEL_ADDR"
            list_json=$(_sms_q list all)
            list_rc=$?
            if [ "$list_rc" -ne 0 ]; then
                code=$(_sms_err_code "$list_json")
                if _sms_is_busy "$code"; then
                    _sms_busy_reply
                    exit 0
                fi
                cgi_error "partial_failure" "$(_sms_err_detail "$list_json" "qsms list failed (rc=$list_rc)")"
                exit 0
            fi

            fail_count=0
            # One "<ST> i,j,.." line per storage holding this sender.
            groups=$(printf '%s' "$list_json" | jq -r --arg addr "$DEL_ADDR" '
                [.msg[]? | select(.sender == $addr)] | group_by(.storage)
                | .[] | "\(.[0].storage) \([.[].index | tostring] | join(","))"' 2>/dev/null)
            # Newline-only splitting, no globbing.
            _sms_ifs="$IFS"
            IFS='
'
            set -f
            for g in $groups; do
                st="${g%% *}"
                idxs="${g#* }"
                case "$st" in ME|SM) ;; *) fail_count=$((fail_count + 1)); continue ;; esac
                case "$idxs" in ''|*[!0-9,]*) fail_count=$((fail_count + 1)); continue ;; esac
                result=$(_sms_q delete "$st" "$idxs")
                rc=$?
                if [ $rc -ne 0 ]; then
                    code=$(_sms_err_code "$result")
                    if _sms_is_busy "$code"; then
                        set +f
                        IFS="$_sms_ifs"
                        _sms_busy_reply
                        exit 0
                    fi
                    failed=$(printf '%s' "$result" | jq -r 'if (.failed | type) == "array" then (.failed | length) else empty end' 2>/dev/null)
                    case "$failed" in ''|*[!0-9]*) failed=1 ;; esac
                    qlog_warn "SMS delete $DEL_ADDR from $st: $failed failed: $(_sms_err_detail "$result" "rc=$rc")"
                    fail_count=$((fail_count + failed))
                fi
            done
            set +f
            IFS="$_sms_ifs"

            if ! sms_sent_delete_addr "$DEL_ADDR"; then
                qlog_error "Could not drop sent SMS records for $DEL_ADDR"
                fail_count=$((fail_count + 1))
            fi

            if [ "$fail_count" -gt 0 ]; then
                cgi_error "partial_failure" "$fail_count message(s) failed to delete"
                exit 0
            fi
            qlog_info "SMS conversation with $DEL_ADDR deleted"
            cgi_success
            exit 0
        fi

        # --- modem slots by index -----------------------------------------------
        # Accepts "indexes": [n, ...] — deletes all storage slots for a
        # (possibly merged multi-part) message, in one qsms call.
        INDEXES_JSON=$(printf '%s' "$POST_DATA" | jq -c 'if .indexes == null then empty else .indexes end' 2>/dev/null)

        if [ -z "$INDEXES_JSON" ] || [ "$INDEXES_JSON" = "null" ]; then
            cgi_error "missing_indexes" "indexes array is required"
            exit 0
        fi

        # Constrained to exactly ME or SM so it can never inject other args
        # into the qsms call.
        case "$STORAGE" in
            ME|SM) : ;;
            *) STORAGE="ME" ;;
        esac

        qlog_info "Deleting SMS indexes from $STORAGE: $INDEXES_JSON"
        # Only plain non-negative integers reach qsms; anything else counts as
        # one failed delete.
        fail_count=0
        idx_list=""
        idx_count=0
        # No globbing while splitting the jq output (an index of "*" must
        # stay a literal invalid index, not expand to file names).
        set -f
        for idx in $(printf '%s' "$INDEXES_JSON" | jq -r '.[]?' 2>/dev/null); do
            case "$idx" in
                *[!0-9]*)
                    qlog_warn "Skipping invalid SMS index: $idx"
                    fail_count=$((fail_count + 1))
                    ;;
                *)
                    idx_list="${idx_list:+$idx_list,}$idx"
                    idx_count=$((idx_count + 1))
                    ;;
            esac
        done
        set +f

        if [ -n "$idx_list" ]; then
            result=$(_sms_q delete "$STORAGE" "$idx_list")
            rc=$?
            if [ $rc -ne 0 ]; then
                code=$(_sms_err_code "$result")
                if _sms_is_busy "$code"; then
                    qlog_error "SMS delete: modem busy ($code)"
                    _sms_busy_reply
                    exit 0
                fi
                # Per-index failures are listed in .failed; anything else
                # (transport error) means every requested index failed.
                failed=$(printf '%s' "$result" | jq -r 'if (.failed | type) == "array" then (.failed | length) else empty end' 2>/dev/null)
                case "$failed" in
                    ''|*[!0-9]*) failed=$idx_count ;;
                esac
                qlog_warn "SMS delete from $STORAGE: $failed index(es) failed: $(_sms_err_detail "$result" "rc=$rc")"
                fail_count=$((fail_count + failed))
            fi
        fi

        if [ "$fail_count" -gt 0 ]; then
            qlog_warn "SMS delete completed with $fail_count failure(s)"
            cgi_error "partial_failure" "$fail_count message(s) failed to delete"
            exit 0
        fi

        qlog_info "SMS delete complete"
        cgi_success
        exit 0
    fi

    # --- action: delete_all --------------------------------------------------
    # qsms clears every index the store reports (not just 0..49).
    if [ "$ACTION" = "delete_all" ]; then
        qlog_info "Deleting all SMS messages (ME + SM + sent log)"

        me_result=$(_sms_q delete ME all)
        me_rc=$?
        sm_result=$(_sms_q delete SM all)
        sm_rc=$?
        sent_detail="ok"
        sms_sent_clear || sent_detail="could not clear the sent log"

        if [ $me_rc -ne 0 ] || [ $sm_rc -ne 0 ] || [ "$sent_detail" != "ok" ]; then
            me_detail="ok"
            sm_detail="ok"
            [ $me_rc -ne 0 ] && me_detail=$(_sms_err_detail "$me_result" "rc=$me_rc")
            [ $sm_rc -ne 0 ] && sm_detail=$(_sms_err_detail "$sm_result" "rc=$sm_rc")
            qlog_error "SMS delete all failed (me_rc=$me_rc sm_rc=$sm_rc): ME='$me_detail' SM='$sm_detail' SENT='$sent_detail'"
            jq -n \
                --arg me_detail "$me_detail" \
                --arg sm_detail "$sm_detail" \
                --arg sent_detail "$sent_detail" \
                '{"success":false,"error":"delete_all_failed","detail":("ME: " + $me_detail + " | SM: " + $sm_detail + " | SENT: " + $sent_detail)}'
            exit 0
        fi

        qlog_info "All SMS messages deleted (ME + SM + sent log)"
        cgi_success
        exit 0
    fi

    # --- action: set_smsc ----------------------------------------------------
    if [ "$ACTION" = "set_smsc" ]; then
        NEW_SMSC=$(printf '%s' "$POST_DATA" | jq -r 'if .addr == null then empty else (.addr | tostring) end' 2>/dev/null)
        # Optional leading +, then 3..20 digits, nothing else.
        digits="${NEW_SMSC#+}"
        case "$digits" in
            ''|*[!0-9]*) digits="" ;;
        esac
        if [ -z "$digits" ] || [ "${#digits}" -lt 3 ] || [ "${#digits}" -gt 20 ]; then
            cgi_error "invalid_smsc" "SMS centre number must be 3 to 20 digits, optionally starting with +"
            exit 0
        fi
        toa=129
        case "$NEW_SMSC" in +*) toa=145 ;; esac

        qlog_info "Setting SMSC to $NEW_SMSC (toa $toa)"
        out=$("$QCMD" "AT+CSCA=\"$NEW_SMSC\",$toa" 2>&1)
        rc=$?
        if [ $rc -ne 0 ]; then
            case "$out" in
                *modem_busy*|*scan_in_progress*)
                    _sms_busy_reply
                    exit 0
                    ;;
            esac
            qlog_error "SMSC write failed (rc=$rc)"
            cgi_error "smsc_write_failed" "The modem did not accept the SMS centre number"
            exit 0
        fi
        if ! printf '%s\n' "$out" | tr -d '\r' | grep -q '^OK'; then
            qlog_error "SMSC write rejected: $(printf '%s' "$out" | tr -d '\r' | tr '\n' ' ')"
            cgi_error "smsc_write_failed" "The modem did not accept the SMS centre number"
            exit 0
        fi

        _sms_smsc_read
        case $? in
            0) ;;
            2) _sms_busy_reply; exit 0 ;;
            *)
                cgi_error "smsc_write_failed" "The SMS centre number could not be read back"
                exit 0
                ;;
        esac
        jq -n --argjson smsc "$(_sms_smsc_json "$SMSC_ADDR")" '{success: true, smsc: $smsc}'
        exit 0
    fi

    # --- Unknown action (mark_read / mark_unread are client-side) -------------
    cgi_error "invalid_action" "action must be send, delete, delete_all or set_smsc"
    exit 0
fi

# --- Method not allowed ------------------------------------------------------
cgi_method_not_allowed
