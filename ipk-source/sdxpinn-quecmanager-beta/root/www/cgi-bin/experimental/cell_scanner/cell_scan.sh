#!/bin/sh

# Set content type to JSON
echo "Content-type: application/json"
echo ""

# Configuration
QUEUE_FILE="/tmp/at_pipe.txt"
RESULT_FILE="/tmp/qscan_result.json"
WORKER_SCRIPT="/www/cgi-bin/experimental/cell_scanner/cell_scan_worker.sh"
PID_FILE="/tmp/cell_scan.pid"
CELL_SCAN_KEYWORD="CELL_SCAN"

# Function to log messages
log_message() {
    logger -t cell_scan "$1"
}

# Function to output JSON response
output_json() {
    local status="$1"
    local message="$2"
    log_message "Sending response: status=$status, message=$message"
    printf '{"status":"%s","message":"%s"}\n' "$status" "$message"
    exit 0
}

# Function to check if worker is running
check_worker_running() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_message "Worker process $pid is running"
            return 0
        fi
        log_message "Removing stale PID file for process $pid"
        rm -f "$PID_FILE"
    fi
    return 1
}

# Function to wait for queue to be ready
wait_for_queue() {
    local retries=0
    while [ ! -f "$QUEUE_FILE" ] && [ $retries -lt 10 ]; do
        touch "$QUEUE_FILE" 2>/dev/null || {
            log_message "Waiting for queue file to be available (attempt $retries)"
            sleep 1
            retries=$((retries + 1))
            continue
        }
        chmod 666 "$QUEUE_FILE" 2>/dev/null
        log_message "Queue file created and permissions set"
        break
    done
}

# Function to add scan entry to queue
add_scan_entry() {
    # Wait for queue file to exist
    wait_for_queue
    
    local entry
    entry=$(printf '{"command":"%s","id":"%s","pid":"%s","timestamp":"%s","priority":"high","status":"queued"}\n' \
        "$CELL_SCAN_KEYWORD" \
        "cell_scan_$$" \
        "$$" \
        "$(date '+%H:%M:%S')")
    
    echo "$entry" >> "$QUEUE_FILE"
    log_message "Added scan entry to queue: $entry"
    
    # Verify entry was added
    if ! grep -q "\"pid\":\"$$\"" "$QUEUE_FILE"; then
        log_message "Failed to verify scan entry in queue"
        return 1
    fi
    
    sync
    return 0
}

# Ensure worker script is executable
chmod +x "$WORKER_SCRIPT" 2>/dev/null
log_message "Ensured worker script is executable"

# Main execution
{
    # If scan is running, return running status
    if check_worker_running; then
        output_json "running" "Cell scan is in progress"
    fi

    # Start new scan
    rm -f "$RESULT_FILE"
    log_message "Starting new worker script: $WORKER_SCRIPT"
    
    # Add scan entry to queue before starting worker
    if ! add_scan_entry; then
        log_message "Failed to add scan entry to queue"
        output_json "error" "Failed to acquire queue lock"
    fi
    
    sh "$WORKER_SCRIPT" >/tmp/cell_scan_worker.log 2>&1 &
    log_message "Worker script started with PID $!"
    output_json "running" "Started new cell scan"
} || {
    # Error handler
    log_message "Script failed with error"
    output_json "error" "Internal error occurred"
}