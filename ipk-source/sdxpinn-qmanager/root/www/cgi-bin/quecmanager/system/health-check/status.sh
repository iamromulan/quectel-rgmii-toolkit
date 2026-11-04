#!/bin/sh
# =============================================================================
# status.sh — GET: System Health Check status.
#   (no query)       the live status JSON, or a "none" placeholder
#   ?test_id=<id>    last 4 KB of that test's raw output
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

qlog_init "cgi_health_check_status"
cgi_headers

STATUS_FILE="/tmp/qmanager_health_check.json"

if [ "$REQUEST_METHOD" != "GET" ]; then
    cgi_method_not_allowed
fi

test_id=""
case "$QUERY_STRING" in
    test_id=*|*'&test_id='*)
        test_id=$(printf '%s' "$QUERY_STRING" | sed -n 's/^\(.*&\)\{0,1\}test_id=\([^&]*\).*/\2/p') ;;
esac

if [ -n "$test_id" ]; then
    case "$test_id" in
        *[!a-z0-9_.]*|.*)
            cgi_error "invalid_test_id" "test_id contains invalid characters"
            exit 0 ;;
    esac
    if [ "${#test_id}" -gt 64 ]; then
        cgi_error "invalid_test_id" "test_id is too long"
        exit 0
    fi
    if [ ! -f "$STATUS_FILE" ]; then
        cgi_error "no_run" "no diagnostic run found"
        exit 0
    fi
    job_id=$(jq -r '.job_id // ""' "$STATUS_FILE" 2>/dev/null)
    case "$job_id" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) cgi_error "no_run" "no diagnostic run found"; exit 0 ;;
    esac
    out_file="/tmp/qmanager_health_check_${job_id}/tests/${test_id}.txt"
    # B4.1: serve evidence only from a root-owned job dir and file
    if ! qm_owned_by_root "/tmp/qmanager_health_check_${job_id}" || ! qm_trusted_file "$out_file"; then
        jq -n --arg id "$test_id" '{success: true, test_id: $id, output: "", truncated: false}'
        exit 0
    fi
    size=$(wc -c < "$out_file" 2>/dev/null | tr -d ' ')
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    truncated=false
    [ "$size" -gt 4096 ] && truncated=true
    tail -c 4096 "$out_file" | jq -R -s --arg id "$test_id" --argjson trunc "$truncated" \
        '{success: true, test_id: $id, output: ., truncated: $trunc}'
    exit 0
fi

if [ -f "$STATUS_FILE" ] && jq -e . "$STATUS_FILE" >/dev/null 2>&1; then
    cat "$STATUS_FILE"
else
    jq -n '{success: true, status: "none", tests: [], summary: {pass: 0, fail: 0, warn: 0, skip: 0, total: 0}}'
fi
