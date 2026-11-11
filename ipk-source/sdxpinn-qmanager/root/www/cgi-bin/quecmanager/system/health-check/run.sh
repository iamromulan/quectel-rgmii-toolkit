#!/bin/sh
# =============================================================================
# run.sh — POST: start the System Health Check runner. Idempotent.
# =============================================================================
# Response: {success:true, job_id, started_at, resumed}
#   resumed:true when a live runner already owns the status file.
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh

qlog_init "cgi_health_check_run"
cgi_headers
cgi_handle_options

STATUS_FILE="/tmp/qmanager_health_check.json"
RUNNER="/usr/bin/qmanager_health_check"
RUNNER_LOG="/tmp/qmanager_health_check.log"

if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_method_not_allowed
fi

if [ ! -x "$RUNNER" ]; then
    cgi_error "runner_missing" "health check runner is not installed"
    exit 0
fi

if [ -f "$STATUS_FILE" ]; then
    existing_status=$(jq -r '.status // ""' "$STATUS_FILE" 2>/dev/null)
    existing_pid=$(jq -r '.pid // 0 | tostring' "$STATUS_FILE" 2>/dev/null)
    case "$existing_pid" in ''|*[!0-9]*) existing_pid=0 ;; esac
    if [ "$existing_status" = "running" ]; then
        if [ "$existing_pid" -gt 0 ] && kill -0 "$existing_pid" 2>/dev/null; then
            jq '{success: true, job_id: (.job_id // ""), started_at: (.started_at // 0), resumed: true}' "$STATUS_FILE"
            exit 0
        fi
        tmp="${STATUS_FILE}.tmp"
        if jq '.status = "error" | .error = "runner exited unexpectedly" | .finished_at = (now | floor)' \
            "$STATUS_FILE" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$STATUS_FILE"
        else
            rm -f "$tmp"
        fi
        qlog_warn "health check runner pid $existing_pid died mid-run; status marked error"
    fi
fi

ts=$(date -u +'%Y%m%d-%H%M%S')
rand=$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
case "$rand" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) rand=$(printf '%04x' $(( $$ % 65536 ))) ;;
esac
job_id="${ts}-${rand}"
started=$(date +%s)

# Double-fork: the runner reparents to init and the CGI returns at once.
( "$RUNNER" "$job_id" </dev/null >"$RUNNER_LOG" 2>&1 & )

qlog_info "spawned health check job $job_id"
jq -n --arg id "$job_id" --argjson s "$started" \
    '{success: true, job_id: $id, started_at: $s, resumed: false}'
