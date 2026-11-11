#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# speedtest_status.sh — CGI Endpoint: Speedtest Status / Progress
# =============================================================================
# Polls the current speedtest state. Returns one of:
#   - idle:     No test running, no cached result
#   - running:  Test in progress, includes current progress line
#   - complete: Test finished, includes full result
#   - error:    Something went wrong
#
# Endpoint: GET /cgi-bin/quecmanager/at_cmd/speedtest_status.sh
#
# NOTE: The Ookla speedtest binary may output ASCII art / banners alongside
# its NDJSON progress lines. We MUST filter for lines starting with '{'
# rather than blindly reading tail -1.
#
# Install location: /www/cgi-bin/quecmanager/at_cmd/speedtest_status.sh
# =============================================================================

# --- Configuration -----------------------------------------------------------
PID_FILE="/tmp/qmanager_speedtest.pid"
OUTPUT_FILE="/tmp/qmanager_speedtest_output"
RESULT_FILE="/tmp/qmanager_speedtest_result.json"
LOCK_FILE="/tmp/qmanager_speedtest.lock"
ERROR_FILE="/tmp/qmanager_speedtest_error"
# A failed run's verdict, kept until the next speedtest_start.sh (which removes
# it) so every poller sees the failure, not only the one that harvested it.
FAILED_FILE="/tmp/qmanager_speedtest_failed.json"

qlog_init "cgi_speedtest_status"
cgi_headers
cgi_handle_options

# Lazily create the lock file; the fd redirect below fails if it's absent.
[ -e "$LOCK_FILE" ] || : > "$LOCK_FILE" 2>/dev/null

# speedtest_flock_wait <fd> <timeout_seconds>
# BusyBox flock has no -w/--timeout, so poll `flock -x -n` (the idiom used in
# sim_registry.sh / cgi_auth.sh / sms.sh). Fractional sleep works on the
# device BusyBox: only the LOSING poller waits, and with two consumers (the
# dialog and the dashboard row) one loses routinely at exactly the moment the
# result lands, so 0.2 s ticks keep its wait near 1 s instead of 3 s. Returns 1
# on timeout; the caller decides the fallback response.
speedtest_flock_wait() {
    _fd="$1"; _wait="$2"; _tries=$((_wait * 5)); _n=0
    while [ "$_n" -lt "$_tries" ]; do
        if flock -x -n "$_fd" 2>/dev/null; then return 0; fi
        sleep 0.2
        _n=$((_n + 1))
    done
    return 1
}

# =============================================================================
# HELPERS
# =============================================================================

# Extract "type" field from a JSON line
get_type() {
    printf '%s' "$1" | jq -r '.type // empty'
}

# Get the last valid JSON line from the output file.
# Speedtest may interleave ASCII progress bars, banners, or blank lines
# between JSON objects. We only want lines that start with '{'.
get_last_json_line() {
    grep '^{' "$OUTPUT_FILE" 2>/dev/null | tail -1
}

# Get the result line specifically (may not be the very last line)
get_result_line() {
    grep '"type":"result"' "$OUTPUT_FILE" 2>/dev/null | tail -1
}

# record_failure <fallback_detail>
# Prints the error response and saves it as FAILED_FILE. The detail is Ookla's
# own last error log line from stderr (e.g. "Cannot open socket") when there is
# one. Without this, only the harvesting poller ever saw the error: everyone
# polling after the harvest found no PID file and no result and got "idle",
# and the dialog dropped back to its start view with no message.
record_failure() {
    _detail=$(grep '"level":"error"' "$ERROR_FILE" 2>/dev/null | tail -1 | jq -r '.message // empty' 2>/dev/null)
    [ -n "$_detail" ] || _detail="$1"
    jq -cn --arg detail "$_detail" '{status: "error", error: "speedtest_failed", detail: $detail}' > "$FAILED_FILE"
    cat "$FAILED_FILE"
}

# =============================================================================
# STATE DETECTION
# =============================================================================

# Case 1: PID file exists — test may be running or just finished
if [ -f "$PID_FILE" ]; then
    SPEEDTEST_PID=$(cat "$PID_FILE" 2>/dev/null)

    if [ -n "$SPEEDTEST_PID" ] && kill -0 "$SPEEDTEST_PID" 2>/dev/null; then
        # =====================================================================
        # RUNNING — process is alive, grab latest JSON progress line
        # =====================================================================
        if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
            LAST_LINE=$(get_last_json_line)

            if [ -n "$LAST_LINE" ]; then
                LINE_TYPE=$(get_type "$LAST_LINE")

                # Determine phase from the type field
                case "$LINE_TYPE" in
                    testStart) PHASE="initializing" ;;
                    ping)      PHASE="ping" ;;
                    download)  PHASE="download" ;;
                    upload)    PHASE="upload" ;;
                    *)         PHASE="running" ;;
                esac
                jq -n --arg phase "$PHASE" --argjson progress "$LAST_LINE" \
                    '{status: "running", phase: $phase, progress: $progress}'
            else
                # Output file has content but no JSON lines yet (just banners)
                echo '{"status":"running","phase":"initializing","progress":null}'
            fi
        else
            # Process started but hasn't written output yet
            echo '{"status":"running","phase":"initializing","progress":null}'
        fi
        exit 0
    else
        # =================================================================
        # JUST FINISHED — process is dead, harvest result.
        #
        # This is the destructive section (rm's PID_FILE/OUTPUT_FILE, writes
        # RESULT_FILE), and two concurrent pollers can race it: poller A can
        # rm OUTPUT_FILE while poller B sits between its own [ -s ] check and
        # its read, turning a good test into a false "speedtest_failed" for B.
        # Serialize the harvest behind an exclusive, short-timeout flock so
        # only one poller harvests; the loser gets a benign "running" (the
        # frontend polls again in 500 ms) instead of an invented error.
        # =================================================================
        (
            if speedtest_flock_wait 9 3; then
                if [ ! -f "$PID_FILE" ]; then
                    # Another poller finished the harvest while we waited for
                    # the lock. speedtest_start.sh clears RESULT_FILE and
                    # FAILED_FILE before every run, so either one is this run's.
                    CACHED_RESULT=$(cat "$RESULT_FILE" 2>/dev/null)
                    case "$CACHED_RESULT" in
                        "{"*)
                            jq -n --argjson result "$CACHED_RESULT" '{status: "complete", result: $result}'
                            ;;
                        *)
                            if [ -s "$FAILED_FILE" ]; then
                                cat "$FAILED_FILE"
                            else
                                echo '{"status":"error","error":"speedtest_failed","detail":"Process exited without producing results"}'
                            fi
                            ;;
                    esac
                elif [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
                    # First try: look specifically for the result line
                    RESULT_LINE=$(get_result_line)

                    if [ -n "$RESULT_LINE" ]; then
                        echo "$RESULT_LINE" > "$RESULT_FILE"
                        jq -n --argjson result "$RESULT_LINE" '{status: "complete", result: $result}'
                    else
                        # No result line — check if last JSON line gives us anything
                        LAST_LINE=$(get_last_json_line)
                        LINE_TYPE=$(get_type "$LAST_LINE")

                        if [ "$LINE_TYPE" = "result" ]; then
                            echo "$LAST_LINE" > "$RESULT_FILE"
                            jq -n --argjson result "$LAST_LINE" '{status: "complete", result: $result}'
                        else
                            record_failure "Process exited without producing results"
                        fi
                    fi
                    # Clean up the (potentially large) progress output file
                    rm -f "$OUTPUT_FILE"
                else
                    record_failure "Process exited with no output"
                fi

                # PID file goes LAST, deliberately. Removing it first would let
                # a poller arriving mid-harvest skip this branch (and the lock),
                # fall through to the cached-result case before RESULT_FILE is
                # written and report "idle", so a finishing test would flicker
                # running -> idle -> complete. Keeping it until the result is
                # durable holds late pollers here, where the lock gives them
                # "running"; a crash mid-harvest leaves it for the next poller.
                rm -f "$PID_FILE"
            else
                # Lock timed out: another poller is harvesting this result now.
                # Never fabricate "error" or "idle"; "running" keeps polling.
                echo '{"status":"running"}'
            fi
        ) 9<"$LOCK_FILE"
        exit 0
    fi
fi

# Case 2: No PID file — check for cached result from previous run
if [ -f "$RESULT_FILE" ] && [ -s "$RESULT_FILE" ]; then
    CACHED_RESULT=$(cat "$RESULT_FILE" 2>/dev/null)
    # Validate it's actually JSON before embedding
    case "$CACHED_RESULT" in
        "{"*)
            jq -n --argjson result "$CACHED_RESULT" '{status: "complete", result: $result}'
            ;;
        *)
            # Corrupted cache — discard it
            rm -f "$RESULT_FILE"
            echo '{"status":"idle"}'
            ;;
    esac
    exit 0
fi

# Case 3: the last run failed. Report it until the next start clears it.
if [ -s "$FAILED_FILE" ]; then
    case "$(cat "$FAILED_FILE" 2>/dev/null)" in
        "{"*) cat "$FAILED_FILE"; exit 0 ;;
        *) rm -f "$FAILED_FILE" ;;
    esac
fi

# Case 4: Nothing — no test running, no previous result
echo '{"status":"idle"}'
