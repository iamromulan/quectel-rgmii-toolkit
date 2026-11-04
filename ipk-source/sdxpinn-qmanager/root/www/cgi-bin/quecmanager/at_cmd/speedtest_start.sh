#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# speedtest_start.sh — CGI Endpoint: Start Speedtest
# =============================================================================
# Spawns a background speedtest-cli process with NDJSON progress output.
# Enforces singleton — only ONE speedtest may run at a time.
#
# Endpoint: POST /cgi-bin/quecmanager/at_cmd/speedtest_start.sh
# Response: {"success": true, "pid": 1234}
#       or: {"success": false, "error": "already_running|not_installed"}
#
# Files written:
#   /tmp/qmanager_speedtest.pid       — PID of running speedtest process
#   /tmp/qmanager_speedtest_output    — NDJSON progress (written by speedtest)
#   /tmp/qmanager_speedtest_result.json — Cached final result (from status CGI)
#
# Install location: /www/cgi-bin/quecmanager/at_cmd/speedtest_start.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_speedtest"
cgi_headers
cgi_handle_options

# --- Configuration -----------------------------------------------------------
PID_FILE="/tmp/qmanager_speedtest.pid"
OUTPUT_FILE="/tmp/qmanager_speedtest_output"
RESULT_FILE="/tmp/qmanager_speedtest_result.json"
ERROR_FILE="/tmp/qmanager_speedtest_error"
FAILED_FILE="/tmp/qmanager_speedtest_failed.json"
# B4.1: the wrapper is executed as root, so it lives in a root-owned dir under /var/run
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh
WRAPPER_DIR=""
WRAPPER_SCRIPT=""

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Read optional server_id from POST body ---------------------------------
cgi_read_post
SERVER_ID=""
if [ -n "$POST_DATA" ]; then
    SERVER_ID=$(printf '%s' "$POST_DATA" | jq -r '.server_id // empty')
fi
# Validate server_id is a plain integer (Ookla IDs are always numeric)
case "$SERVER_ID" in
    ''|*[!0-9]*) SERVER_ID="" ;;
esac

# --- Check: speedtest-cli installed? -----------------------------------------
if ! command -v speedtest >/dev/null 2>&1; then
    qlog_error "Speedtest binary not found"
    cgi_error "not_installed" "speedtest-cli is not installed"
    exit 0
fi

# --- Check: already running? -------------------------------------------------
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        qlog_warn "Speedtest already running (PID: $OLD_PID)"
        cgi_error "already_running" "A speedtest is already in progress"
        exit 0
    fi
    # Stale PID file — process is dead, clean up
    qlog_info "Cleaning up stale speedtest PID file (PID: $OLD_PID)"
    rm -f "$PID_FILE"
fi

# --- Clean up previous run ---------------------------------------------------
rm -f "$OUTPUT_FILE" "$RESULT_FILE" "$ERROR_FILE" "$FAILED_FILE"

# --- Resolve full path to speedtest binary -----------------------------------
SPEEDTEST_BIN=$(command -v speedtest)

# --- Build the wrapper script ------------------------------------------------
# STRATEGY: Write the ENTIRE wrapper using a single-quoted heredoc ('WEOF')
# so NOTHING is expanded by the outer shell. Then use sed to patch in the
# two dynamic values (speedtest binary path and file paths).
#
# This avoids all heredoc escaping headaches with $$, \$, etc.
# --------------------------------------------------------------------------
WRAPPER_DIR="$(qm_run_dir 2>/dev/null)/speedtest"
if [ "$WRAPPER_DIR" = "/speedtest" ] || ! qm_root_dir "$WRAPPER_DIR" 0700; then
    qlog_error "Cannot create root-owned speedtest work dir"
    cgi_error "start_failed" "Cannot prepare speedtest"
    exit 0
fi
WRAPPER_SCRIPT="$WRAPPER_DIR/run.sh"
rm -f "$WRAPPER_SCRIPT"
cat > "$WRAPPER_SCRIPT" << 'WEOF'
#!/bin/sh

# Source the system profile to get the full login environment.
# The Ookla speedtest binary (C++) crashes with:
#   "basic_string::_M_construct null not valid"
# when environment variables it expects are NULL. uhttpd strips nearly all
# env vars from CGI processes. Sourcing /etc/profile gives us the same
# environment an SSH session would have.
[ -f /etc/profile ] && . /etc/profile

# Safety net: explicitly set critical vars if profile didn't cover them
export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export LOGNAME="${LOGNAME:-root}"
export TMPDIR="${TMPDIR:-/tmp}"
export LANG="${LANG:-C}"
export LC_ALL="${LC_ALL:-C}"
export TERM="${TERM:-xterm}"
export HOSTNAME="${HOSTNAME:-$(cat /proc/sys/kernel/hostname 2>/dev/null || echo localhost)}"
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# Write our PID so the status CGI can track us
echo $$ > /tmp/qmanager_speedtest.pid

# exec replaces this shell with speedtest — PID stays the same
exec __SPEEDTEST_BIN__ \
    --accept-license \
    --accept-gdpr \
    -f json \
    -p yes \
    --progress-update-interval=250 \
    __SERVER_FLAG__ \
    > /tmp/qmanager_speedtest_output \
    2> /tmp/qmanager_speedtest_error
WEOF

# Patch in the resolved speedtest binary path and optional server flag
sed -i "s|__SPEEDTEST_BIN__|${SPEEDTEST_BIN}|" "$WRAPPER_SCRIPT"
if [ -n "$SERVER_ID" ]; then
    sed -i "s|__SERVER_FLAG__|-s ${SERVER_ID}|" "$WRAPPER_SCRIPT"
else
    sed -i "s|__SERVER_FLAG__||" "$WRAPPER_SCRIPT"
fi

chmod +x "$WRAPPER_SCRIPT"

# --- Launch in a new session -------------------------------------------------
# setsid detaches from uhttpd's process group so the test survives CGI exit.
# Detach via subshell (pure POSIX, no setsid needed)
( "$WRAPPER_SCRIPT" </dev/null >/dev/null 2>&1 & )

# Give the wrapper time to source profile, start, and write PID
sleep 0.8

if [ -f "$PID_FILE" ]; then
    NEW_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$NEW_PID" ] && kill -0 "$NEW_PID" 2>/dev/null; then
        qlog_info "Speedtest started (PID: $NEW_PID, bin: $SPEEDTEST_BIN)"
        jq -n --argjson pid "$NEW_PID" '{success: true, pid: $pid}'
    else
        # Process wrote PID but already died — grab stderr for diagnostics
        ERR_MSG=$(cat "$ERROR_FILE" 2>/dev/null | head -1)
        qlog_error "Speedtest exited immediately (PID: $NEW_PID): $ERR_MSG"
        rm -f "$PID_FILE" "$OUTPUT_FILE"
        jq -n --arg detail "$ERR_MSG" '{success: false, error: "start_failed", detail: $detail}'
    fi
else
    ERR_MSG=$(cat "$ERROR_FILE" 2>/dev/null | head -1)
    qlog_error "Speedtest failed to write PID file: $ERR_MSG"
    rm -f "$OUTPUT_FILE"
    jq -n --arg detail "$ERR_MSG" '{success: false, error: "start_failed", detail: $detail}'
fi
