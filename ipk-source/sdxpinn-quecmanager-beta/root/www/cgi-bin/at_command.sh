#!/bin/sh

# Set content-type for JSON response
echo "Content-type: application/json"
echo ""

# Define file paths and configuration
QUEUE_FILE="/tmp/at_pipe.txt"
LOG_FILE="/var/log/at_commands.log"
LOCK_KEYWORD="AT_COMMAND_LOCK"
CELL_SCAN_KEYWORD="CELL_SCAN"
MAX_WAIT=6  # Maximum seconds to wait for lock
COMMAND_TIMEOUT=4  # Timeout for individual AT commands

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
    logger -t at_commands "$1"
}

# Function to output error in JSON format
output_error() {
    printf '{"status":"error","message":"%s","timestamp":"%s"}\n' "$1" "$(date '+%H:%M:%S')"
    exit 1
}

# Function to wait for high-priority operations
wait_for_high_priority() {
    while grep -q "\"command\":\"$CELL_SCAN_KEYWORD\"" "$QUEUE_FILE" || \
          grep -q "\"priority\":\"high\"" "$QUEUE_FILE"; do
        log_message "Waiting for high-priority operation to complete"
        sleep 1
    done
}

# Function to clean and add lock with simplified timeout logic
add_clean_lock() {
    local TIMESTAMP=$(date +%s)
    local WAIT_START=$(date +%s)
    
    # First, wait for any high-priority operations
    wait_for_high_priority
    
    while true; do
        local CURRENT_TIME=$(date +%s)
        
        # After MAX_WAIT seconds, forcibly remove any existing lock
        if [ $((CURRENT_TIME - WAIT_START)) -ge $MAX_WAIT ]; then
            sed -i "/${LOCK_KEYWORD}/d" "$QUEUE_FILE"
            log_message "Removed existing lock after $MAX_WAIT seconds timeout"
        fi
        
        # Add our lock entry with high priority
        printf '{"id":"%s","timestamp":"%s","command":"%s","status":"lock","pid":"%s","start_time":"%s","priority":"high"}\n' \
            "${LOCK_KEYWORD}" \
            "$(date '+%H:%M:%S')" \
            "${LOCK_KEYWORD}" \
            "$$" \
            "$TIMESTAMP" >> "$QUEUE_FILE"
        
        # Verify our lock was written
        if grep -q "\"pid\":\"$$\".*\"start_time\":\"$TIMESTAMP\"" "$QUEUE_FILE"; then
            log_message "Lock created by PID $$ at $TIMESTAMP"
            trap 'remove_lock; exit' INT TERM EXIT
            return 0
        fi
        
        if [ $((CURRENT_TIME - WAIT_START)) -lt $MAX_WAIT ]; then
            sleep 1
        else
            log_message "Failed to acquire lock after $MAX_WAIT seconds"
            return 1
        fi
    done
}

# Function to remove lock
remove_lock() {
    sed -i "/\"pid\":\"$$\"/d" "$QUEUE_FILE"
    log_message "Lock removed by PID $$"
}

# Function to escape JSON
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

# Simplified AT command execution with basic response validation
execute_at_command() {
    local CMD="$1"
    local RETRY_COUNT=0
    local MAX_RETRIES=3
    local OUTPUT=""
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        # Execute command with -D parameter to include OK/ERROR responses
        OUTPUT=$(timeout $COMMAND_TIMEOUT sms_tool at "$CMD" -D 2>&1)
        local EXIT_CODE=$?
        
        if [ $EXIT_CODE -eq 0 ]; then
            # Check if response contains "CME" for execution failure
            if echo "$OUTPUT" | grep -q "CME"; then
                echo "$OUTPUT"
                return 2  # Command execution failed
            # Check if response contains OK (simple grep)
            elif echo "$OUTPUT" | grep -q "OK"; then
                echo "$OUTPUT"
                return 0
            else
                # Any other response is considered unsupported
                echo "$OUTPUT"
                return 1
            fi
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        [ $RETRY_COUNT -lt $MAX_RETRIES ] && sleep 1
    done
    
    log_message "Command failed after $MAX_RETRIES attempts: $CMD"
    return 1
}

# Get command from query string
QUERY_STRING="${QUERY_STRING:-}"
RAW_COMMAND=$(echo "${QUERY_STRING}" | sed 's/^command=//')

if [ -n "${RAW_COMMAND}" ]; then
    # Decode URL-encoded command
    AT_COMMAND=$(printf '%b' "${RAW_COMMAND}" | sed -e 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g' | xargs -0 echo -e)
    
    # Set timeout for the entire script
    ( sleep 60; kill -TERM $$ 2>/dev/null ) & 
    TIMEOUT_PID=$!
    
    if ! add_clean_lock; then
        kill $TIMEOUT_PID 2>/dev/null
        output_error "Failed to acquire lock for command processing"
    fi
    
    # Execute command and capture result
    RESULT=$(execute_at_command "${AT_COMMAND}")
    EXIT_CODE=$?
    
    # Clean up
    remove_lock
    kill $TIMEOUT_PID 2>/dev/null
    
    # Escape command and result for JSON
    ESCAPED_COMMAND=$(escape_json "${AT_COMMAND}")
    ESCAPED_RESULT=$(escape_json "${RESULT}")
    
    # Return response based on simplified exit codes
    if [ $EXIT_CODE -eq 0 ]; then
        # Command succeeded with OK response
        printf '{"status":"success","command":"%s","response":"%s","timestamp":"%s"}\n' \
            "${ESCAPED_COMMAND}" "${ESCAPED_RESULT}" "$(date '+%H:%M:%S')"
    elif [ $EXIT_CODE -eq 2 ]; then
        # Command contains CME - execution failed
        printf '{"status":"error","command":"%s","message":"Command execution failed","response":"%s","timestamp":"%s"}\n' \
            "${ESCAPED_COMMAND}" "${ESCAPED_RESULT}" "$(date '+%H:%M:%S')"
    else
        # Any other response is considered unsupported
        printf '{"status":"error","command":"%s","message":"Unsupported command","response":"%s","timestamp":"%s"}\n' \
            "${ESCAPED_COMMAND}" "${ESCAPED_RESULT}" "$(date '+%H:%M:%S')"
    fi
else
    output_error "No command provided"
fi