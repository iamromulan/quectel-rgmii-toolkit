#!/bin/sh

# Configuration
QUEUE_DIR="/tmp/at_queue"
RESULTS_DIR="$QUEUE_DIR/results"
TOKEN_FILE="$QUEUE_DIR/token"
RESULT_FILE="/tmp/qscan_result.json"
PID_FILE="/tmp/cell_scan.pid"
SCAN_COMMAND="AT+QSCAN=3,1"
SCAN_TIMEOUT=200
LOCK_ID="CELL_SCAN_$(date +%s)_$$"

# Enable shell debugging for better logging
set -x

# Function to log messages
log_message() {
    local level="${2:-info}"
    logger -t at_queue -p "daemon.$level" "cell_scan_worker: $1"
}

# Function to clean up stale temporary files
cleanup_stale_files() {
    log_message "Cleaning up stale temporary files" "info"
    
    # Clean up old start_time files (older than 1 hour)
    find "$QUEUE_DIR" -name "start_time.qscan_*" -type f -mmin +60 -delete 2>/dev/null
    
    # Clean up any start_time files that match our current process just in case
    find "$QUEUE_DIR" -name "start_time.qscan_*_$" -type f -delete 2>/dev/null
    
    log_message "Stale file cleanup completed" "info"
}

# Function to check directories and permissions
check_environment() {
    log_message "Checking environment" "info"
    
    # Clean up stale files first
    cleanup_stale_files
    
    # Check if directories exist, create if they don't
    if [ ! -d "$QUEUE_DIR" ]; then
        mkdir -p "$QUEUE_DIR"
        log_message "Created queue directory: $QUEUE_DIR" "info"
    fi
    
    if [ ! -d "$RESULTS_DIR" ]; then
        mkdir -p "$RESULTS_DIR"
        log_message "Created results directory: $RESULTS_DIR" "info"
    fi
    
    # Check permissions
    chmod 755 "$QUEUE_DIR" 2>/dev/null
    chmod 755 "$RESULTS_DIR" 2>/dev/null
    
    # Check if sms_tool exists and is executable
    if ! which sms_tool >/dev/null 2>&1; then
        log_message "sms_tool not found in PATH" "error"
        return 1
    fi
    
    # Test directory write permissions
    if ! touch "$QUEUE_DIR/test_$$" 2>/dev/null; then
        log_message "Cannot write to $QUEUE_DIR" "error"
        return 1
    fi
    rm -f "$QUEUE_DIR/test_$$" 2>/dev/null
    
    if ! touch "$RESULTS_DIR/test_$$" 2>/dev/null; then
        log_message "Cannot write to $RESULTS_DIR" "error"
        return 1
    fi
    rm -f "$RESULTS_DIR/test_$$" 2>/dev/null
    
    log_message "Environment check passed" "info"
    return 0
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

# Function to check if scan is already running
check_running() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log_message "Cell scan already running (PID: $pid)" "warn"
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    return 1
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
                # Try again
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

# Release token directly
release_token() {
    if [ -f "$TOKEN_FILE" ]; then
        local current_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id' 2>/dev/null)
        if [ "$current_holder" = "$LOCK_ID" ]; then
            rm -f "$TOKEN_FILE" 2>/dev/null
            log_message "Released token" "info"
            return 0
        fi
        log_message "Token held by $current_holder, not by us ($LOCK_ID)" "warn"
    fi
    return 1
}

# Main execution
main() {
    # Start logging
    log_message "Worker script started" "info"

    # Check if already running
    if check_running; then
        log_message "Cell scan already running, exiting" "warn"
        exit 1
    fi

    # Create PID file
    echo "$$" > "$PID_FILE"
    chmod 644 "$PID_FILE" 2>/dev/null
    log_message "Created PID file: $$" "info"
    
    # Set up cleanup on exit
    trap 'log_message "Cleaning up and exiting" "info"; release_token; rm -f "$PID_FILE"; exit' INT TERM EXIT
    
    # Acquire token for AT command execution
    if ! acquire_token; then
        log_message "Failed to acquire token, exiting" "error"
        rm -f "$PID_FILE"
        exit 1
    fi
    
    log_message "Token acquired, executing scan command: $SCAN_COMMAND" "info"

    # Execute scan with native timeout option (without relying on timeout command)
    # Use the -t option of sms_tool instead of the timeout command
    log_message "Executing command with timeout: $SCAN_TIMEOUT seconds" "info"
    SCAN_OUTPUT=$(sms_tool at "$SCAN_COMMAND" -t $SCAN_TIMEOUT 2>&1 | clean_output)
    SCAN_STATUS=$?
    log_message "Command execution completed with status: $SCAN_STATUS" "info"
    
    # Process and store result
    if [ $SCAN_STATUS -eq 0 ]; then
        # Check if output contains valid scan data or error
        if echo "$SCAN_OUTPUT" | grep -q "+QSCAN"; then
            # Set timestamp
            TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
            
            # Valid scan data found - don't add the "Scan completed but no valid data" prefix
            log_message "Scan completed with valid data" "info"
            
            # Create the result file with proper JSON formatting
            printf '{"status":"success","timestamp":"%s","output":%s}\n' \
                "$TIMESTAMP" \
                "$(printf '%s' "$SCAN_OUTPUT" | sed 's/"/\\"/g' | jq -R -s '.')" > "$RESULT_FILE"
            chmod 644 "$RESULT_FILE" 2>/dev/null
        else
            # No valid scan data, but command completed
            log_message "Command completed but no valid scan data found: $SCAN_OUTPUT" "warn"
            SCAN_OUTPUT="Scan completed but no valid data returned: $SCAN_OUTPUT"
            
            # Create a result file indicating partial success
            printf '{"status":"partial","timestamp":"%s","output":%s}\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" \
                "$(printf '%s' "$SCAN_OUTPUT" | sed 's/"/\\"/g' | jq -R -s '.')" > "$RESULT_FILE"
            chmod 644 "$RESULT_FILE" 2>/dev/null
        fi
        
        # Generate a command ID for the AT queue results format - use actual PID instead of $
        local my_pid="$$"
        local cmd_id="qscan_$(date +%s)_${my_pid}"
        local end_time=$(date +%s)
        local start_time=$end_time
        local duration=0
        
        # Store start time for future reference
        echo "$start_time" > "$QUEUE_DIR/start_time.$cmd_id"
        
        log_message "Creating AT queue result with ID: $cmd_id" "info"
        
        # Create JSON response in the AT queue format
        local response=$(cat << EOF
{
    "command": {
        "id": "$cmd_id",
        "text": "$SCAN_COMMAND",
        "timestamp": "$(date -Iseconds)"
    },
    "response": {
        "status": "success",
        "raw_output": "$(escape_json "$SCAN_OUTPUT")",
        "completion_time": "$end_time",
        "duration_ms": $duration
    }
}
EOF
)
        
        # Save the response to the AT queue results directory
        printf "%s" "$response" > "$RESULTS_DIR/$cmd_id.json"
        chmod 644 "$RESULTS_DIR/$cmd_id.json"
        
        # Clean up temporary files
        rm -f "$QUEUE_DIR/start_time.$cmd_id"
        log_message "Cleaned up temporary files" "info"
        
        # Release the token
        release_token
        return 0
    else
        log_message "Scan failed with status: $SCAN_STATUS" "error"
        printf '{"status":"error","timestamp":"%s","message":"Scan failed"}\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" > "$RESULT_FILE"
        chmod 644 "$RESULT_FILE" 2>/dev/null
        
        # Release the token
        release_token
        return 1
    fi
}

# Execute main function with proper error handling
{
    log_message "Worker script started with PID $$" "info"
    
    # Check environment before proceeding
    check_environment || {
        log_message "Environment check failed, aborting" "error"
        exit 1
    }
    
    # Execute main function
    main || {
        log_message "Main function failed with error $?" "error"
        release_token
        rm -f "$PID_FILE"
        exit 1
    }
} 2>/tmp/cell_scan_worker_debug.log || {
    log_message "Script failed with error" "error"
    release_token
    rm -f "$PID_FILE"
    exit 1
}