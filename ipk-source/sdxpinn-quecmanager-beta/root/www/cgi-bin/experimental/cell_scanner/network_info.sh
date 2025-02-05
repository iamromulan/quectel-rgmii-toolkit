#!/bin/sh

# Set content-type for JSON response
echo "Content-type: application/json"
echo ""

# Define file paths and configuration
QUEUE_FILE="/tmp/at_pipe.txt"
TEMP_FILE="/tmp/network_info_output.txt"
LOG_FILE="/var/log/network_info.log"
LOCK_KEYWORD="AT_COMMAND_LOCK"
MAX_WAIT=6
COMMAND_TIMEOUT=4

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
    logger -t network_info "$1"
}

# Function to output JSON error
output_error() {
    printf '{"status":"error","message":"%s","timestamp":"%s"}\n' "$1" "$(date '+%H:%M:%S')"
    exit 1
}

# Function to clean and add lock
add_clean_lock() {
    local TIMESTAMP=$(date +%s)
    local WAIT_START=$(date +%s)
    
    while true; do
        local CURRENT_TIME=$(date +%s)
        
        if [ $((CURRENT_TIME - WAIT_START)) -ge $MAX_WAIT ]; then
            sed -i "/${LOCK_KEYWORD}/d" "$QUEUE_FILE"
            log_message "Removed existing lock after $MAX_WAIT seconds timeout"
        fi
        
        printf '{"id":"%s","timestamp":"%s","command":"%s","status":"lock","pid":"%s","start_time":"%s","priority":"high"}\n' \
            "${LOCK_KEYWORD}" \
            "$(date '+%H:%M:%S')" \
            "${LOCK_KEYWORD}" \
            "$$" \
            "$TIMESTAMP" >> "$QUEUE_FILE"
        
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

# Function to execute AT command with retries
execute_at_command() {
    local CMD="$1"
    local RETRY_COUNT=0
    local MAX_RETRIES=3
    local OUTPUT=""
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        OUTPUT=$(timeout $COMMAND_TIMEOUT sms_tool at "$CMD" -D 2>&1)
        local EXIT_CODE=$?
        
        if [ $EXIT_CODE -eq 0 ]; then
            if echo "$OUTPUT" | grep -q "CME ERROR"; then
                RETRY_COUNT=$((RETRY_COUNT + 1))
                [ $RETRY_COUNT -lt $MAX_RETRIES ] && sleep 1
                continue
            fi
            echo "$OUTPUT"
            return 0
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
        [ $RETRY_COUNT -lt $MAX_RETRIES ] && sleep 1
    done
    
    log_message "Command failed after $MAX_RETRIES attempts: $CMD"
    return 1
}

# Function to check network mode
check_network_mode() {
    local OUTPUT=$(execute_at_command "AT+QENG=\"servingcell\"")
    echo "$OUTPUT" > "$TEMP_FILE"
    
    # Check for both LTE and NR5G-NSA (NSA mode)
    if echo "$OUTPUT" | grep -q "\"LTE\"" && echo "$OUTPUT" | grep -q "\"NR5G-NSA\""; then
        echo "NRLTE"
    # Check for LTE only
    elif echo "$OUTPUT" | grep -q "\"LTE\""; then
        echo "LTE"
    # Check for NR5G-SA
    elif echo "$OUTPUT" | grep -q "\"NR5G-SA\""; then
        echo "NR5G"
    else
        echo "UNKNOWN"
    fi
}

# Function to check NR5G measurement info setting
check_nr5g_meas_info() {
    local OUTPUT=$(execute_at_command "AT+QNWCFG=\"nr5g_meas_info\"")
    if echo "$OUTPUT" | grep -q "\"nr5g_meas_info\",1"; then
        return 0
    else
        return 1
    fi
}

# Function to escape JSON string
escape_json_string() {
    echo "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | tr -d '\n' | sed 's/\r//g'
}

# Function to parse and format output as JSON
format_output_json() {
    local MODE="$1"
    local NEIGHBOR_OUTPUT="$2"
    local MEAS_OUTPUT="$3"
    
    # Basic JSON structure
    printf '{"status":"success","timestamp":"%s","mode":"%s","data":{' "$(date '+%H:%M:%S')" "$MODE"
    
    # Add neighbor cell info if available
    if [ -n "$NEIGHBOR_OUTPUT" ]; then
        printf '"neighborCells":"%s"' "$(escape_json_string "$NEIGHBOR_OUTPUT")"
    fi
    
    # Add measurement info if available
    if [ -n "$MEAS_OUTPUT" ]; then
        [ -n "$NEIGHBOR_OUTPUT" ] && printf ','
        printf '"meas":"%s"' "$(escape_json_string "$MEAS_OUTPUT")"
    fi
    
    printf '}}\n'
}

# Main execution
{
    if ! add_clean_lock; then
        output_error "Failed to acquire lock for command processing"
    fi
    
    # Check network mode
    NETWORK_MODE=$(check_network_mode)
    log_message "Detected network mode: $NETWORK_MODE"
    
    SERVING_OUTPUT=""
    MEAS_OUTPUT=""
    
    case "$NETWORK_MODE" in
        "NRLTE")
            SERVING_OUTPUT=$(execute_at_command "AT+QENG=\"neighbourcell\"")
            if ! check_nr5g_meas_info; then
                MEAS_OUTPUT=$(execute_at_command "AT+QNWCFG=\"nr5g_meas_info\",1;+QNWCFG=\"nr5g_meas_info\"")
            else
                MEAS_OUTPUT=$(execute_at_command "AT+QNWCFG=\"nr5g_meas_info\"")
            fi
            ;;
        "LTE")
            SERVING_OUTPUT=$(execute_at_command "AT+QENG=\"neighbourcell\"")
            ;;
        "NR5G")
            if ! check_nr5g_meas_info; then
                MEAS_OUTPUT=$(execute_at_command "AT+QNWCFG=\"nr5g_meas_info\",1;+QNWCFG=\"nr5g_meas_info\"")
            else
                MEAS_OUTPUT=$(execute_at_command "AT+QNWCFG=\"nr5g_meas_info\"")
            fi
            ;;
        *)
            output_error "Unknown or unsupported network mode"
            ;;
    esac
    
    format_output_json "$NETWORK_MODE" "$SERVING_OUTPUT" "$MEAS_OUTPUT"
    remove_lock
    rm -f "$TEMP_FILE"
    
} || {
    # Error handler
    remove_lock
    rm -f "$TEMP_FILE"
    output_error "Internal error occurred"
}