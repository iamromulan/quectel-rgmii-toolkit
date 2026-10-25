#!/bin/sh
# AT command helper library — shared utilities for CGI scripts and daemons.
# Source after qlog.sh or cgi_base.sh so qlog functions are already available.

[ -n "$_CGI_AT_LOADED" ] && return 0
_CGI_AT_LOADED=1

# Ensure qlog_warn is a no-op if sourced before logging is initialised.
command -v qlog_warn >/dev/null 2>&1 || qlog_warn() { :; }

# ---------------------------------------------------------------------------
# strip_at_response <raw>
# Remove the command echo, trailing OK, and ERROR lines from a raw qcmd
# response, then print the payload on stdout.
# ---------------------------------------------------------------------------
strip_at_response() {
    printf '%s' "$1" | tr -d '\r' | sed -e '1d' -e '/^OK$/d' -e '/^ERROR$/d'
}

# ---------------------------------------------------------------------------
# run_at <at_command>
# Execute an AT command via qcmd and print the stripped response.
# Returns 0 on success, 1 on failure (no output written on failure).
#
# Usage:
#   result=$(run_at "AT+CGDCONT?") || { handle_error; }
# ---------------------------------------------------------------------------
run_at() {
    local raw
    raw=$(qcmd "$1" 2>/dev/null)
    local rc=$?
    if [ $rc -ne 0 ] || [ -z "$raw" ]; then
        qlog_warn "AT command failed: $1 (rc=$rc)"
        return 1
    fi
    case "$raw" in
        *ERROR*)
            qlog_warn "AT command returned ERROR: $1"
            return 1
            ;;
    esac
    strip_at_response "$raw"
}

# ---------------------------------------------------------------------------
# at_exec <at_command>
# Execute an AT command via qcmd WITHOUT a subshell so the caller can branch on
# the kind of failure. Sets global AT_RAW to the raw reply ("" on a transport
# failure).
# Returns: 0 reply without ERROR
#          1 transport failure (lock timeout, broker/channel down: qcmd rc!=0
#            with empty stdout) -> callers answer cgi_error "modem_error"
#          2 the modem answered ERROR / +CME ERROR (qcmd rc 0)
# A bare *ERROR* match reads a transport failure (empty reply) as success.
#
# Usage:
#   at_exec 'AT+QCFG="usbnet",1'
#   case $? in 1) cgi_error modem_error ...;; 2) cgi_error usbnet_failed ...;; esac
# ---------------------------------------------------------------------------
at_exec() {
    local rc
    AT_RAW=$(qcmd "$1" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$AT_RAW" ]; then
        qlog_warn "AT transport failure: $1 (rc=$rc)"
        AT_RAW=""
        return 1
    fi
    case "$AT_RAW" in
        *ERROR*)
            qlog_warn "AT command returned ERROR: $1"
            return 2
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# parse_cgdcont <raw_response>
# Parse AT+CGDCONT? response into a JSON array [{cid, pdp_type, apn}].
# Outputs JSON array to stdout. Outputs "[]" if input is empty or unmatched.
#
# Usage:
#   profiles_json=$(parse_cgdcont "$cgdcont_resp")
# ---------------------------------------------------------------------------
parse_cgdcont() {
    local raw="$1"
    if [ -z "$raw" ]; then
        echo "[]"
        return
    fi
    printf '%s' "$raw" | awk -F'"' '
        /\+CGDCONT:/ {
            split($0, a, /[,]/)
            gsub(/[^0-9]/, "", a[1])
            cid = a[1]
            pdp = $2
            apn = $4
            if (cid != "") {
                printf "%s\t%s\t%s\n", cid, pdp, apn
            }
        }
    ' | jq -Rsc '
        split("\n") | map(select(length > 0) | split("\t") |
            {cid: (.[0] | tonumber), pdp_type: .[1], apn: .[2]}
        )
    '
}

# ---------------------------------------------------------------------------
# validate_imei <imei>
# Validate that <imei> is exactly 15 decimal digits.
# Returns 0 if valid, 1 if invalid (including empty input).
#
# Usage:
#   validate_imei "$NEW_IMEI" || { echo "Invalid IMEI"; exit 1; }
# ---------------------------------------------------------------------------
validate_imei() {
    case "$1" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# wait_modem_ready <seconds>
# Block for <seconds> to allow the modem AT interface to come up after boot.
# Used by one-shot boot daemons that must wait before issuing AT commands.
#
# Usage:
#   wait_modem_ready "$SETTLE_TIME"
# ---------------------------------------------------------------------------
wait_modem_ready() {
    local secs="${1:-10}"
    local i=0
    while [ "$i" -lt "$secs" ]; do
        sleep 1
        i=$((i + 1))
    done
}
