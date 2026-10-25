#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# cell_scan_status.sh — CGI Endpoint: Cell Scan Status
# =============================================================================
# Polled by the frontend to check cell scan progress.
# Returns idle/running/complete/error with results when available.
#
# Endpoint: GET /cgi-bin/quecmanager/at_cmd/cell_scan_status.sh
# Response:
#   {"status": "idle"}
#   {"status": "running"}
#   {"status": "complete", "results": [...]}
#   {"status": "error", "message": "..."}
#
# Install location: /www/cgi-bin/quecmanager/at_cmd/cell_scan_status.sh
# =============================================================================

# --- Configuration -----------------------------------------------------------
PID_FILE="/tmp/qmanager_cell_scan.pid"
RESULT_FILE="/tmp/qmanager_cell_scan_result.json"
ERROR_FILE="/tmp/qmanager_cell_scan_error"

qlog_init "cgi_cell_scan_status"
cgi_headers
cgi_handle_options

# --- Check: scanner process running? -----------------------------------------
if [ -f "$PID_FILE" ]; then
    SCAN_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$SCAN_PID" ] && kill -0 "$SCAN_PID" 2>/dev/null; then
        jq -n '{"status":"running"}'
        exit 0
    fi
    # Process died — clean up stale PID
    rm -f "$PID_FILE"
fi

# --- Check: result file present? ---------------------------------------------
if [ -f "$RESULT_FILE" ]; then
    # Stream the results directly — no need to copy into a wrapper
    jq -n --slurpfile results "$RESULT_FILE" '{"status":"complete","results":$results[0]}'
    exit 0
fi

# --- Check: error file present? ----------------------------------------------
# Read-only: a GET must not consume the error, or one lost poll drops it and
# the page falls back to idle. The start CGI and the worker clear it.
# Checked AFTER the result: if a stray older error and a newer result both
# exist, the result wins (a real failure always removes the result first).
if [ -f "$ERROR_FILE" ]; then
    ERR_MSG=$(cat "$ERROR_FILE" 2>/dev/null | head -1)
    jq -n --arg msg "$ERR_MSG" '{"status":"error","message":$msg}'
    exit 0
fi

# --- Default: idle (no scan has been run yet) ---------------------------------
jq -n '{"status":"idle"}'
