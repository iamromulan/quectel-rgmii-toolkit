#!/bin/sh
# AT Queue Manager for OpenWRT with Preemption Support and Token System
# Located in /www/cgi-bin/services/at_queue_manager

# Constants
QUEUE_DIR="/tmp/at_queue"
QUEUE_FILE="$QUEUE_DIR/queue"
ACTIVE_FILE="$QUEUE_DIR/active"
RESULTS_DIR="$QUEUE_DIR/results"
LOCK_DIR="$QUEUE_DIR/lock"
TOKEN_FILE="$QUEUE_DIR/token"
MAX_TIMEOUT=240
CLEANUP_INTERVAL=300  # 5 minutes in seconds
RESULTS_MAX_AGE=3600   # 1 hour in seconds
POLL_INTERVAL=0.01
PREEMPTION_THRESHOLD=2  # 3 seconds threshold for preemption
TOKEN_TIMEOUT=30  # seconds before token expires

# Utility function for JSON escaping
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

# Exclusive lock functions
acquire_lock() {
    local timeout=10
    local attempt=0
    
    while [ $attempt -lt $timeout ]; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            logger -t at_queue -p daemon.debug "Lock acquired"
            return 0
        fi
        
        sleep 0.1
        attempt=$((attempt + 1))
    done
    
    logger -t at_queue -p daemon.error "Failed to acquire lock after $timeout attempts"
    return 1
}

release_lock() {
    if [ -d "$LOCK_DIR" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null
        logger -t at_queue -p daemon.debug "Lock released"
        return 0
    fi
    
    logger -t at_queue -p daemon.error "Lock directory doesn't exist"
    return 1
}

# Ensure required directories exist
init_queue_system() {
    mkdir -p "$QUEUE_DIR" "$RESULTS_DIR"
    touch "$QUEUE_FILE"
    chmod 755 "$QUEUE_DIR"
    chmod 644 "$QUEUE_FILE"
    chmod 755 "$RESULTS_DIR"
    logger -t at_queue -p daemon.info "Queue system initialized"
}

# Cleanup old results and tracking files
cleanup_old_results() {
    local current_time=$(date +%s)
    
    # Clean up old execution tracking files
    find "$QUEUE_DIR" -name "pid.*" -type f -mmin +60 -delete 2>/dev/null
    find "$QUEUE_DIR" -name "*.exit" -type f -mmin +60 -delete 2>/dev/null
    find "$QUEUE_DIR" -name "start_time.*" -type f -mmin +60 -delete 2>/dev/null
    logger -t at_queue -p daemon.debug "Cleaned up old tracking files"
    
    # Use find with -delete and basic timestamp check for OpenWRT
    find "$RESULTS_DIR" -name "*.json" -type f -mmin +60 -delete 2>/dev/null || {
        # Fallback method if find fails
        for file in "$RESULTS_DIR"/*.json; do
            [ -f "$file" ] || continue
            local file_time=$(stat -c %Y "$file")
            if [ $((current_time - file_time)) -gt $RESULTS_MAX_AGE ]; then
                rm -f "$file"
            fi
        done
    }
    
    # Check for expired token
    if [ -f "$TOKEN_FILE" ]; then
        local token_time=$(cat "$TOKEN_FILE" | jsonfilter -e '@.timestamp')
        if [ $((current_time - token_time)) -gt $TOKEN_TIMEOUT ]; then
            local token_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id')
            logger -t at_queue -p daemon.warn "Removing expired token from $token_holder"
            rm -f "$TOKEN_FILE"
        fi
    fi
    
    logger -t at_queue -p daemon.info "Cleanup: Removed files older than 1 hour"
}

# Generate unique command ID
generate_command_id() {
    echo "$(date +%s)_$(head -c 8 /dev/urandom | hexdump -v -e '1/1 "%02x"')"
}

# Start tracking command execution time
start_execution_tracking() {
    local cmd_id="$1"
    local pid="$2"
    local start_time=$(date +%s)
    
    echo "$start_time" > "$QUEUE_DIR/start_time.$cmd_id"
    echo "$pid" > "$QUEUE_DIR/pid.$cmd_id"
    chmod 644 "$QUEUE_DIR/start_time.$cmd_id"
    chmod 644 "$QUEUE_DIR/pid.$cmd_id"
    logger -t at_queue -p daemon.debug "Started tracking command $cmd_id (PID: $pid)"
}

# Check if running command should be preempted
should_preempt() {
    local current_cmd_id="$1"
    local new_priority="$2"
    
    if [ ! -f "$QUEUE_DIR/start_time.$current_cmd_id" ]; then
        logger -t at_queue -p daemon.debug "No start time found for $current_cmd_id"
        return 1
    fi
    
    local start_time=$(cat "$QUEUE_DIR/start_time.$current_cmd_id")
    local current_time=$(date +%s)
    local execution_time=$((current_time - start_time))
    
    # Get current command's priority
    local current_priority
    if [ -f "$ACTIVE_FILE" ]; then
        current_priority=$(cat "$ACTIVE_FILE" | jsonfilter -e '@.priority')
    else
        logger -t at_queue -p daemon.debug "No active command found"
        return 1
    fi
    
    if [ $execution_time -gt $PREEMPTION_THRESHOLD ] && [ $new_priority -lt $current_priority ]; then
        logger -t at_queue -p daemon.info "Command $current_cmd_id (priority $current_priority) running for ${execution_time}s is eligible for preemption by priority $new_priority"
        return 0
    fi
    
    logger -t at_queue -p daemon.debug "Command $current_cmd_id not eligible for preemption (time: ${execution_time}s, current priority: $current_priority, new priority: $new_priority)"
    return 1
}

# Handle command preemption
preempt_command() {
    local cmd_id="$1"
    local pid_file="$QUEUE_DIR/pid.$cmd_id"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        logger -t at_queue -p daemon.info "Preempting command $cmd_id (PID: $pid)"
        
        # Send SIGTERM first
        kill -TERM $pid 2>/dev/null
        
        # Brief wait for graceful termination
        sleep 0.1
        
        # Force kill if still running
        if kill -0 $pid 2>/dev/null; then
            kill -KILL $pid 2>/dev/null
            logger -t at_queue -p daemon.warn "Forced termination of command $cmd_id"
        fi
        
        # Record preemption result
        write_preemption_result "$cmd_id"
        
        # Cleanup command files
        rm -f "$pid_file" "$QUEUE_DIR/start_time.$cmd_id" "$QUEUE_DIR/$cmd_id.exit"
        [ -f "$ACTIVE_FILE" ] && rm -f "$ACTIVE_FILE"
        
        logger -t at_queue -p daemon.info "Command $cmd_id preemption complete"
        return 0
    fi
    
    logger -t at_queue -p daemon.warn "No PID file found for command $cmd_id"
    return 1
}

# Record result for preempted command
write_preemption_result() {
    local cmd_id="$1"
    local end_time=$(date +%s%3N)
    local start_time
    
    if [ -f "$QUEUE_DIR/start_time.$cmd_id" ]; then
        start_time=$(cat "$QUEUE_DIR/start_time.$cmd_id")000
    else
        start_time=$end_time
    fi
    
    local duration=$((end_time - start_time))
    local command_text=$(cat "$ACTIVE_FILE" | jsonfilter -e '@.command')
    
    local response=$(cat << EOF
{
    "command": {
        "id": "$cmd_id",
        "text": "$(escape_json "$command_text")",
        "timestamp": "$(date -Iseconds)"
    },
    "response": {
        "status": "preempted",
        "raw_output": "Command preempted by higher priority task",
        "completion_time": "$end_time",
        "duration_ms": $duration
    }
}
EOF
)
    
    printf "%s" "$response" > "$RESULTS_DIR/$cmd_id.json"
    chmod 644 "$RESULTS_DIR/$cmd_id.json"
    logger -t at_queue -p daemon.info "Recorded preemption result for command $cmd_id (duration: ${duration}ms)"
}

# Request a token for direct sms_tool execution
request_token() {
    local requestor_id="$1"
    local priority="${2:-10}"
    local timeout="${3:-10}"
    
    # Acquire lock first
    if ! acquire_lock; then
        logger -t at_queue -p daemon.error "Failed to acquire lock for token request"
        echo "{\"error\":\"Could not acquire lock\",\"status\":\"denied\"}"
        return 1
    fi
    
    # Check if token file exists (someone else has the token)
    if [ -f "$TOKEN_FILE" ]; then
        local current_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id')
        local current_priority=$(cat "$TOKEN_FILE" | jsonfilter -e '@.priority')
        local timestamp=$(cat "$TOKEN_FILE" | jsonfilter -e '@.timestamp')
        local current_time=$(date +%s)
        
        # Check for expired token (> TOKEN_TIMEOUT seconds old)
        if [ $((current_time - timestamp)) -gt $TOKEN_TIMEOUT ]; then
            logger -t at_queue -p daemon.warn "Found expired token from $current_holder, releasing"
            rm -f "$TOKEN_FILE"
        # Check for priority preemption
        elif [ $priority -lt $current_priority ]; then
            logger -t at_queue -p daemon.info "Preempting token from $current_holder (priority: $current_priority) for $requestor_id (priority: $priority)"
            rm -f "$TOKEN_FILE"
        else
            # Token in use and cannot be preempted
            release_lock
            echo "{\"status\":\"denied\",\"holder\":\"$current_holder\",\"priority\":$current_priority}"
            return 1
        fi
    fi
    
    # Also check if there's an active command from the queue
    if [ -f "$ACTIVE_FILE" ]; then
        local active_id=$(cat "$ACTIVE_FILE" | jsonfilter -e '@.id')
        local active_priority=$(cat "$ACTIVE_FILE" | jsonfilter -e '@.priority')
        
        # Only preempt if priority is higher
        if [ $priority -ge $active_priority ]; then
            release_lock
            echo "{\"status\":\"denied\",\"holder\":\"$active_id\",\"priority\":$active_priority}"
            return 1
        fi
        
        logger -t at_queue -p daemon.info "Direct execution with higher priority than active queue command"
    fi
    
    # Grant token
    local token_data="{\"id\":\"$requestor_id\",\"priority\":$priority,\"timestamp\":$(date +%s)}"
    echo "$token_data" > "$TOKEN_FILE"
    chmod 644 "$TOKEN_FILE"
    
    release_lock
    echo "{\"status\":\"granted\",\"id\":\"$requestor_id\",\"timeout\":$timeout}"
    return 0
}

# Release a previously acquired token
release_token() {
    local requestor_id="$1"
    
    if ! acquire_lock; then
        logger -t at_queue -p daemon.error "Failed to acquire lock for token release"
        return 1
    fi
    
    if [ -f "$TOKEN_FILE" ]; then
        local current_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id')
        
        if [ "$current_holder" = "$requestor_id" ]; then
            rm -f "$TOKEN_FILE"
            logger -t at_queue -p daemon.debug "Token released by $requestor_id"
            release_lock
            echo "{\"status\":\"released\"}"
            return 0
        else
            logger -t at_queue -p daemon.warn "Token release attempted by $requestor_id but held by $current_holder"
        fi
    else
        logger -t at_queue -p daemon.warn "Token release attempted but no token exists"
    fi
    
    release_lock
    echo "{\"status\":\"not_found\"}"
    return 1
}

# Add command to queue with preemption support
enqueue_command() {
    local cmd="$1"
    local priority="${2:-10}"
    local cmd_id=$(generate_command_id)
    local timestamp=$(date -Iseconds)
    
    # Ensure queue directory exists
    [ ! -d "$QUEUE_DIR" ] && init_queue_system
    
    logger -t at_queue -p daemon.info "Enqueuing command: $cmd (priority: $priority, id: $cmd_id)"
    
    # Acquire lock for queue modification
    if ! acquire_lock; then
        logger -t at_queue -p daemon.error "Failed to acquire lock for enqueuing command"
        echo "{\"error\":\"Queue lock acquisition failed\",\"command\":\"$cmd\"}"
        return 1
    fi
    
    # Check for active command that can be preempted
    if [ -f "$ACTIVE_FILE" ]; then
        local active_cmd_id=$(cat "$ACTIVE_FILE" | jsonfilter -e '@.id')
        if should_preempt "$active_cmd_id" "$priority"; then
            preempt_command "$active_cmd_id"
        fi
    fi
    
    # Create command entry
    local entry="{\"id\":\"$cmd_id\",\"command\":\"$(escape_json "$cmd")\",\"priority\":$priority,\"timestamp\":\"$timestamp\"}"
    
    if [ "$priority" = "1" ]; then
        # High priority - prepend to queue
        local temp_file=$(mktemp)
        echo "$entry" > "$temp_file"
        cat "$QUEUE_FILE" >> "$temp_file"
        mv "$temp_file" "$QUEUE_FILE"
        chmod 644 "$QUEUE_FILE"
        logger -t at_queue -p daemon.info "Added high priority command to front of queue"
    else
        # Normal priority - append to queue
        echo "$entry" >> "$QUEUE_FILE"
        logger -t at_queue -p daemon.info "Added normal priority command to end of queue"
    fi
    
    # Release lock
    release_lock
    
    echo "{\"command_id\":\"$cmd_id\",\"status\":\"queued\"}"
}

# Get next command from queue
dequeue_command() {
    if [ ! -s "$QUEUE_FILE" ]; then
        return 1
    fi
    
    # Acquire lock
    if ! acquire_lock; then
        logger -t at_queue -p daemon.error "Failed to acquire lock for dequeuing command"
        return 1
    fi
    
    local cmd_entry=$(head -n 1 "$QUEUE_FILE")
    local temp_file=$(mktemp)
    tail -n +2 "$QUEUE_FILE" > "$temp_file"
    mv "$temp_file" "$QUEUE_FILE"
    chmod 644 "$QUEUE_FILE"
    
    echo "$cmd_entry" > "$ACTIVE_FILE"
    chmod 644 "$ACTIVE_FILE"
    
    # Release lock
    release_lock
    
    logger -t at_queue -p daemon.debug "Dequeued command: $(echo "$cmd_entry" | jsonfilter -e '@.command')"
    echo "$cmd_entry"
}

# Clean and format AT command output
clean_output() {
    local output="$1"
    
    # First format AT command responses for readability
    output=$(echo "$output" | sed -E '
        # Add newline after AT commands
        s/(AT\+[A-Z0-9]+[^ ]*) +/\1\n/g
        # Add newline before +RESPONSE lines
        s/ +(\+[A-Z0-9]+:)/\n\1/g
        # Add newline before OK/ERROR
        s/ +(OK|ERROR)$/\n\1/g
    ')
    
    # Then escape the formatted output for JSON
    output=$(escape_json "$output")
    
    echo "$output"
}

# Execute AT command with optimized timeout handling
execute_with_timeout() {
    local command="$1"
    local timeout="$2"
    local cmd_id="$3"
    local output_file=$(mktemp)
    
    # Start command in background with immediate output
    (sms_tool -D at "$command" > "$output_file" 2>&1; echo $? > "$QUEUE_DIR/$cmd_id.exit") &
    local pid=$!
    
    # Start execution tracking
    start_execution_tracking "$cmd_id" "$pid"
    
    logger -t at_queue -p daemon.debug "Started command execution: $command (PID: $pid)"
    
    # Wait for completion with shorter polling interval
    local start_time=$(date +%s)
    local elapsed=0
    
    while [ $elapsed -lt "$timeout" ]; do
        if [ -f "$QUEUE_DIR/$cmd_id.exit" ]; then
            local exit_code=$(cat "$QUEUE_DIR/$cmd_id.exit")
            local output=$(cat "$output_file")
            
            # Cleanup
            rm -f "$QUEUE_DIR/pid.$cmd_id" "$QUEUE_DIR/$cmd_id.exit" "$output_file" "$QUEUE_DIR/start_time.$cmd_id"
            
            logger -t at_queue -p daemon.debug "Command completed with exit code $exit_code"
            echo "$output"
            return $exit_code
        fi
        
        elapsed=$(($(date +%s) - start_time))
        sleep $POLL_INTERVAL
    done
    
    # Handle timeout
    if [ -f "$QUEUE_DIR/pid.$cmd_id" ]; then
        local pid=$(cat "$QUEUE_DIR/pid.$cmd_id")
        kill $pid 2>/dev/null
        sleep 0.1
        # Force kill if still running
        if kill -0 $pid 2>/dev/null; then
            kill -KILL $pid 2>/dev/null
        fi
        
        local partial_output=$(cat "$output_file" 2>/dev/null || echo "")
        
        # Cleanup
        rm -f "$QUEUE_DIR/pid.$cmd_id" "$QUEUE_DIR/$cmd_id.exit" "$output_file" "$QUEUE_DIR/start_time.$cmd_id"
        
        logger -t at_queue -p daemon.warn "Command timed out after $timeout seconds"
        echo "${partial_output:-Command timed out after $timeout seconds}"
    fi
    
    return 124
}

# Execute AT command and handle response
execute_command() {
    local cmd_entry="$1"
    local cmd_id=$(echo "$cmd_entry" | jsonfilter -e '@.id')
    local cmd_text=$(echo "$cmd_entry" | jsonfilter -e '@.command')
    local priority=$(echo "$cmd_entry" | jsonfilter -e '@.priority')
    
    local start_time=$(date +%s%3N)
    
    logger -t at_queue -p daemon.info "Executing command $cmd_id: $cmd_text (priority: $priority)"
    
    # Execute command with timeout
    local result=$(execute_with_timeout "$cmd_text" $MAX_TIMEOUT "$cmd_id")
    local exit_code=$?
    local end_time=$(date +%s%3N)
    local duration=$((end_time - start_time))
    
    # Determine status and log level
    local status="error"
    local log_level="error"
    
    if [ $exit_code -eq 124 ]; then
        status="timeout"
        logger -t at_queue -p daemon.error "Command $cmd_id timed out after ${duration}ms"
    elif echo "$result" | grep -q "OK"; then
        status="success"
        log_level="info"
        logger -t at_queue -p daemon.info "Command $cmd_id completed successfully in ${duration}ms"
    elif echo "$result" | grep -q "CME ERROR"; then
        status="cme_error"
        logger -t at_queue -p daemon.error "Command $cmd_id failed with CME ERROR in ${duration}ms"
    else
        logger -t at_queue -p daemon.error "Command $cmd_id failed with general error in ${duration}ms"
    fi
    
    # Clean and escape the output
    local clean_result=$(clean_output "$result")
    
    # Create JSON response
    local response=$(cat << EOF
{
    "command": {
        "id": "$cmd_id",
        "text": "$(escape_json "$cmd_text")",
        "timestamp": "$(date -Iseconds)"
    },
    "response": {
        "status": "$status",
        "raw_output": "$clean_result",
        "completion_time": "$end_time",
        "duration_ms": $duration
    }
}
EOF
)
    
    # Acquire lock for writing result
    if ! acquire_lock; then
        logger -t at_queue -p daemon.error "Failed to acquire lock for writing result"
    else
        # Save response
        printf "%s" "$response" > "$RESULTS_DIR/$cmd_id.json"
        chmod 644 "$RESULTS_DIR/$cmd_id.json"
        
        # Clean up active file
        rm -f "$ACTIVE_FILE"
        
        # Release lock
        release_lock
    fi
    
    echo "$response"
}

# Main queue processing function
process_queue() {
    init_queue_system
    local last_cleanup=$(date +%s)
    local last_log=$(date +%s)  # Add a timestamp for less frequent logging
    
    # Make sure the lock directory doesn't exist at startup
    [ -d "$LOCK_DIR" ] && rmdir "$LOCK_DIR" 2>/dev/null
    
    logger -t at_queue -p daemon.info "Started queue processing daemon"
    
    while true; do
        # Quick cleanup check
        local current_time=$(date +%s)
        if [ $((current_time - last_cleanup)) -ge $CLEANUP_INTERVAL ]; then
            cleanup_old_results
            last_cleanup=$current_time
        fi
        
        # Skip processing if token is granted to someone
        if [ -f "$TOKEN_FILE" ]; then
            local token_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id')
            local token_time=$(cat "$TOKEN_FILE" | jsonfilter -e '@.timestamp')
            local current_time=$(date +%s)
            
            # Check for expired token
            if [ $((current_time - token_time)) -gt $TOKEN_TIMEOUT ]; then
                logger -t at_queue -p daemon.warn "Removing expired token from $token_holder"
                rm -f "$TOKEN_FILE"
            else
                # Log pause status only every 5 seconds to reduce log spam
                if [ $((current_time - last_log)) -ge 5 ]; then
                    logger -t at_queue -p daemon.debug "Queue processing paused, token held by $token_holder"
                    last_log=$current_time
                fi
                sleep $POLL_INTERVAL
                continue
            fi
        fi
        
        # Process queue if not empty and no active command
        if [ -s "$QUEUE_FILE" ] && [ ! -f "$ACTIVE_FILE" ]; then
            local cmd_entry=$(dequeue_command)
            if [ -n "$cmd_entry" ]; then
                execute_command "$cmd_entry"
            fi
        fi
        
        sleep $POLL_INTERVAL
    done
}

# CGI command handling
if [ "${SCRIPT_NAME}" != "" ]; then
    # Output headers
    if [ "$HTTP_HEADERS" != "0" ]; then
        echo "Content-Type: application/json"
        echo ""
    fi
    
    # Parse query string for CGI mode
    eval $(echo "$QUERY_STRING" | sed 's/&/;/g')
    
    case "$action" in
        "enqueue")
            if [ -n "$command" ]; then
                logger -t at_queue -p daemon.info "CGI: Received enqueue request for command: $command"
                enqueue_command "$command" "$priority"
            else
                logger -t at_queue -p daemon.error "CGI: Empty command received"
                echo "{\"error\":\"No command specified\"}"
            fi
            ;;
        "status")
            if [ -f "$ACTIVE_FILE" ]; then
                logger -t at_queue -p daemon.debug "CGI: Status request - queue active"
                cat "$ACTIVE_FILE"
            else
                logger -t at_queue -p daemon.debug "CGI: Status request - queue idle"
                echo "{\"status\":\"idle\"}"
            fi
            ;;
        "request_token")
            if [ -n "$id" ]; then
                logger -t at_queue -p daemon.info "Token request from $id (priority: ${priority:-10})"
                request_token "$id" "${priority:-10}" "${timeout:-10}"
            else
                logger -t at_queue -p daemon.error "Token request missing ID"
                echo "{\"error\":\"No requestor ID specified\",\"status\":\"denied\"}"
            fi
            ;;
        "release_token")
            if [ -n "$id" ]; then
                logger -t at_queue -p daemon.info "Token release from $id"
                release_token "$id"
            else
                logger -t at_queue -p daemon.error "Token release missing ID"
                echo "{\"error\":\"No requestor ID specified\",\"status\":\"denied\"}"
            fi
            ;;
        *)
            logger -t at_queue -p daemon.error "CGI: Invalid action received: $action"
            echo "{\"error\":\"Invalid action\"}"
            ;;
    esac
    exit 0
fi

# CLI command handling
if [ "$1" = "enqueue" ] && [ -n "$2" ]; then
    enqueue_command "$2" "${3:-10}"
    exit $?
fi

# If not run as CGI, start queue processing
if [ "${SCRIPT_NAME}" = "" ] && [ -z "$1" ]; then
    process_queue
fi