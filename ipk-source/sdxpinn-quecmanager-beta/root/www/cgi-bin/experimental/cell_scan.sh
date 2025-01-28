#!/bin/sh

# Set content-type for JSON response
echo "Content-type: application/json"
echo ""

# Configuration
QUEUE_FILE="/tmp/at_pipe.txt"
CELL_SCAN_KEYWORD="CELL_SCAN"
MAX_SCAN_TIME=180  # 3 minutes maximum scan time
LOCK_WAIT_TIME=6   # Maximum seconds to wait for lock

# Function to output error in JSON format
output_error() {
    printf '{"status":"error","error":"%s","output":""}\n' "$1"
    exit 1
}

# Function to create and verify queue entry
create_queue_entry() {
    local TIMESTAMP=$(date +%s)
    local entry=$(printf '{"id":"%s","timestamp":"%s","command":"%s","status":"scanning","pid":"%s","start_time":"%s","priority":"high"}\n' \
        "${CELL_SCAN_KEYWORD}" \
        "$(date '+%H:%M:%S')" \
        "${CELL_SCAN_KEYWORD}" \
        "$$" \
        "$TIMESTAMP")
    
    echo "$entry" >> "$QUEUE_FILE"
    
    # Verify our entry was written
    if grep -q "\"pid\":\"$$\".*\"start_time\":\"$TIMESTAMP\"" "$QUEUE_FILE"; then
        logger -t cell_scan "Queue entry created successfully"
        return 0
    else
        logger -t cell_scan "Failed to create queue entry"
        return 1
    fi
}

# Remove our entry from the queue
remove_queue_entry() {
    sed -i "/\"pid\":\"$$\"/d" "$QUEUE_FILE"
    logger -t cell_scan "Removed entry for PID $$"
}

# Escape special characters for JSON string
escape_json() {
    printf '%s' "$1" | awk '
    BEGIN { RS="\n"; ORS="\\n" }
    {
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        gsub(/\r/, "")
        print
    }' | sed 's/\\n$//'
}

# Execute cell scan with proper timeout handling
execute_cell_scan() {
    local tmp_output=$(mktemp)
    local scan_pid
    
    # Start scan in background
    (sms_tool at "AT+QSCAN=3,1" -t $MAX_SCAN_TIME > "$tmp_output" 2>/dev/null) &
    scan_pid=$!
    logger -t cell_scan "Started QSCAN with PID: $scan_pid"
    
    # Wait for scan to complete or timeout
    local wait_time=0
    while [ $wait_time -lt $MAX_SCAN_TIME ]; do
        if ! kill -0 $scan_pid 2>/dev/null; then
            break
        fi
        sleep 1
        wait_time=$((wait_time + 1))
    done
    
    # Check if we need to kill the scan
    if [ $wait_time -ge $MAX_SCAN_TIME ]; then
        kill $scan_pid 2>/dev/null
        wait $scan_pid 2>/dev/null
        logger -t cell_scan "Scan timed out after $MAX_SCAN_TIME seconds"
        output_error "Scan timed out"
    fi
    
    logger -t cell_scan "Scan completed in $wait_time seconds"
    
    # Process and output results
    if [ -s "$tmp_output" ]; then
        local escaped_output=$(escape_json "$(cat "$tmp_output")")
        printf '{"status":"success","output":"%s"}\n' "$escaped_output"
    else
        output_error "No scan results"
    fi
    
    rm -f "$tmp_output"
}

# Main execution
main() {
    # Set global timeout
    ( sleep $MAX_SCAN_TIME; kill -TERM $$ 2>/dev/null ) &
    TIMEOUT_PID=$!
    
    # Ensure queue file exists
    touch "$QUEUE_FILE"
    
    # Create queue entry
    if ! create_queue_entry; then
        output_error "Failed to create queue entry"
    fi
    
    # Register cleanup handler
    trap 'remove_queue_entry; kill $TIMEOUT_PID 2>/dev/null; exit' INT TERM EXIT
    
    # Execute scan and output results
    execute_cell_scan
    
    # Cleanup
    kill $TIMEOUT_PID 2>/dev/null
    remove_queue_entry
}

# Start main execution
main