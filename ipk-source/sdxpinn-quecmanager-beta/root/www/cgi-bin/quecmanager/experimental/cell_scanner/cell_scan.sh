#!/bin/sh

# Set content type to JSON
echo "Content-type: application/json"
echo ""

# Configuration
QUEUE_DIR="/tmp/at_queue"
RESULTS_DIR="$QUEUE_DIR/results"
TOKEN_FILE="$QUEUE_DIR/token"
RESULT_FILE="/tmp/qscan_result.json"
WORKER_SCRIPT="/www/cgi-bin/quecmanager/experimental/cell_scanner/cell_scan_worker.sh"
PID_FILE="/tmp/cell_scan.pid"
SCAN_COMMAND="AT+QSCAN=3,1"
SCAN_TIMEOUT=200
LOCK_ID="CELL_SCAN_$(date +%s)_$$"

# Function to log messages
log_message() {
    local level="${2:-info}"
    logger -t at_queue -p "daemon.$level" "cell_scan: $1"
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

# Enhanced JSON string escaping function
escape_json() {
    printf '%s' "$1" | awk '
    BEGIN { RS="\n"; ORS="\\n" }
    {
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        gsub(/\r/, "")
        gsub(/\t/, "\\t")
        gsub(/\f/, "\\f")
        gsub(/\b/, "\\b")
        print
    }
    ' | sed 's/\\n$//'
}

# Acquire token directly with high priority
acquire_token() {
    local priority=1  # Highest priority for cell scan
    local max_attempts=10
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        # Check if token file exists
        if [ -f "$TOKEN_FILE" ]; then
            local current_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id' 2>/dev/null)
            local current_priority=$(cat "$TOKEN_FILE" | jsonfilter -e '@.priority' 2>/dev/null)
            local timestamp=$(cat "$TOKEN_FILE" | jsonfilter -e '@.timestamp' 2>/dev/null)
            local current_time=$(date +%s)
            
            # Check for expired token (> 30 seconds old)
            if [ $((current_time - timestamp)) -gt 30 ] || [ -z "$current_holder" ]; then
                # Remove expired token
                rm -f "$TOKEN_FILE" 2>/dev/null
            elif [ $priority -lt $current_priority ]; then
                # Preempt lower priority token
                log_message "Preempting token from $current_holder (priority: $current_priority)" "info"
                rm -f "$TOKEN_FILE" 2>/dev/null
            else
                # Try again - higher priority token exists
                log_message "Token held by $current_holder with priority $current_priority, retrying..." "debug"
                sleep 0.5
                attempt=$((attempt + 1))
                continue
            fi
        fi
        
        # Try to create token file
        echo "{\"id\":\"$LOCK_ID\",\"priority\":$priority,\"timestamp\":$(date +%s)}" > "$TOKEN_FILE" 2>/dev/null
        chmod 644 "$TOKEN_FILE" 2>/dev/null
        
        # Verify we got the token
        local holder=$(cat "$TOKEN_FILE" 2>/dev/null | jsonfilter -e '@.id' 2>/dev/null)
        if [ "$holder" = "$LOCK_ID" ]; then
            log_message "Successfully acquired token with priority $priority" "info"
            return 0
        fi
        
        sleep 0.5
        attempt=$((attempt + 1))
    done
    
    log_message "Failed to acquire token after $max_attempts attempts" "error"
    return 1
}

# Main execution
{
    # If scan is running, return running status
    if check_worker_running; then
        output_json "running" "Cell scan is in progress"
    fi

    # Start new scan
    rm -f "$RESULT_FILE"
    log_message "Starting new cell scan" "info"
    
    # Ensure worker script is executable
    chmod +x "$WORKER_SCRIPT" 2>/dev/null
    
    # Start worker script with proper parameters
    log_message "Attempting to start worker script: $WORKER_SCRIPT" "info"
    
    # Check if worker script exists
    if [ ! -f "$WORKER_SCRIPT" ]; then
        log_message "Worker script not found: $WORKER_SCRIPT" "error"
        output_json "error" "Worker script not found"
    fi
    
    # Ensure QUEUE_DIR exists
    mkdir -p "$QUEUE_DIR" "$RESULTS_DIR"
    chmod 755 "$QUEUE_DIR"
    chmod 755 "$RESULTS_DIR"
    
    # Start worker with debug logging
    WORKER_PID=$ 
    (sh "$WORKER_SCRIPT" >/tmp/cell_scan_worker.log 2>&1) &
    WORKER_PID=$!
    log_message "Worker script started with PID $WORKER_PID" "info"
    
    # The worker process runs in the background and completes quickly
    # We don't need to check if it's still running as it might finish before we check
    log_message "Worker process $WORKER_PID started in background" "info"
    
    # Instead of checking if the process is running, check if it created the result file
    sleep 2
    if [ -f "$RESULT_FILE" ]; then
        log_message "Worker successfully created result file" "info"
    else
        log_message "Waiting for worker to create result file..." "info"
        # If no result file yet, check for errors
        if [ -f "/tmp/cell_scan_worker.log" ]; then
            WORKER_LOG=$(cat "/tmp/cell_scan_worker.log" | head -20)
            log_message "Worker log: $WORKER_LOG" "info"
        fi
    fi
    output_json "running" "Started new cell scan"
} || {
    # Error handler
    log_message "Script failed with error" "error"
    output_json "error" "Internal error occurred"
}