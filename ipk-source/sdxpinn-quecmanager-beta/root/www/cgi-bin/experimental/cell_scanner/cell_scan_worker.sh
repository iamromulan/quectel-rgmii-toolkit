# Modified cell_scan_worker.sh
#!/bin/sh

# Configuration
QUEUE_FILE="/tmp/at_pipe.txt"
RESULT_FILE="/tmp/qscan_result.json"
PID_FILE="/tmp/cell_scan.pid"
CELL_SCAN_KEYWORD="CELL_SCAN"
SCAN_COMMAND="AT+QSCAN=3,1"
SCAN_TIMEOUT=200

# Function to log messages
log_message() {
    logger -t cell_scan_worker "$1"
}

# Function to clean AT command output
clean_output() {
    while IFS= read -r line; do
        case "$line" in
        "OK" | "" | *"ERROR"*)
            continue
            ;;
        *)
            printf '%s\n' "$line"
            ;;
        esac
    done | sed 's/\r//g' | tr '\n' '\r' | sed 's/\r$//' | tr '\r' '\n'
}

# Function to check if scan is already running
check_running() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    return 1
}

# Function to remove scan entry
remove_scan_entry() {
    if [ -f "$QUEUE_FILE" ]; then
        sed -i "/\"pid\":\"$$\"/d" "$QUEUE_FILE"
        sync
    fi
    if [ -f "$PID_FILE" ]; then
        rm -f "$PID_FILE"
    fi
    log_message "Scan entry and PID file removed"
}

# Main execution
main() {
    # Start logging
    log_message "Worker script started"

    # Check if already running
    if check_running; then
        log_message "Cell scan already running"
        exit 1
    fi

    # Create PID file
    echo "$$" >"$PID_FILE"
    chmod 666 "$PID_FILE" 2>/dev/null
    log_message "Created PID file: $$"

    # Execute scan with timeout and process output
    log_message "Executing scan command: $SCAN_COMMAND"
    SCAN_OUTPUT=$(timeout $SCAN_TIMEOUT sms_tool at "$SCAN_COMMAND" -t $SCAN_TIMEOUT 2>&1 | clean_output)
    SCAN_STATUS=$?

    # Process and store result
    if [ $SCAN_STATUS -eq 0 ] && [ -n "$SCAN_OUTPUT" ]; then
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        printf '{"status":"success","timestamp":"%s","output":"%s"}\n' \
            "$TIMESTAMP" \
            "$(printf '%s' "$SCAN_OUTPUT" | jq -R -s '.')" >"$RESULT_FILE"
        chmod 666 "$RESULT_FILE" 2>/dev/null

        log_message "Scan completed successfully"
        remove_scan_entry
        exit 0
    else
        log_message "Scan failed with status: $SCAN_STATUS"
        printf '{"status":"error","timestamp":"%s","message":"Scan failed"}\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" >"$RESULT_FILE"
        chmod 666 "$RESULT_FILE" 2>/dev/null
        remove_scan_entry
        exit 1
    fi
}

# Execute main function with proper error handling
{
    main
} || {
    log_message "Script failed with error"
    remove_scan_entry
    exit 1
}