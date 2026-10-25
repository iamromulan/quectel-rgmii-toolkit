#!/bin/sh
# =============================================================================
# clear.sh — POST: delete the previous System Health Check run artifacts.
#   Refuses with job_running while a runner is alive.
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh

qlog_init "cgi_health_check_clear"
cgi_headers
cgi_handle_options

STATUS_FILE="/tmp/qmanager_health_check.json"
RUNNER="/usr/bin/qmanager_health_check"

if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_method_not_allowed
fi

if [ -f "$STATUS_FILE" ]; then
    existing_status=$(jq -r '.status // ""' "$STATUS_FILE" 2>/dev/null)
    existing_pid=$(jq -r '.pid // 0 | tostring' "$STATUS_FILE" 2>/dev/null)
    case "$existing_pid" in ''|*[!0-9]*) existing_pid=0 ;; esac
    if [ "$existing_status" = "running" ] && [ "$existing_pid" -gt 0 ] && kill -0 "$existing_pid" 2>/dev/null; then
        cgi_error "job_running" "a diagnostic job is currently running"
        exit 0
    fi
fi

if [ ! -x "$RUNNER" ]; then
    cgi_error "runner_missing" "health check runner is not installed"
    exit 0
fi

out=$("$RUNNER" --clear </dev/null 2>&1)
rc=$?
if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    [ "$rc" -eq 0 ] && qlog_info "cleared health check artifacts"
    printf '%s\n' "$out"
else
    qlog_error "health check clear failed rc=$rc"
    cgi_error "clear_failed" "could not clear the previous run"
fi
