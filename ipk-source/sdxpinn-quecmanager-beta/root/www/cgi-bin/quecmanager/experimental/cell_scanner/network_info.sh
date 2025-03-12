#!/bin/sh

# Set content-type for JSON response
echo "Content-type: application/json"
echo ""

# Define paths and constants to match queue system
QUEUE_DIR="/tmp/at_queue"
RESULTS_DIR="$QUEUE_DIR/results"
TOKEN_FILE="$QUEUE_DIR/token"
TEMP_FILE="/tmp/network_info_output.txt"
LOCK_ID="NETWORK_INFO_$(date +%s)_$$"
COMMAND_TIMEOUT=8  # Increased timeout
MAX_TOKEN_WAIT=10
PRIORITY=5  # Medium-high priority (between cell scan and normal commands)

# Function to log messages
log_message() {
    local level="${2:-info}"
    logger -t at_queue -p "daemon.$level" "network_info: $1"
}

# Function to output JSON error
output_error() {
    printf '{"status":"error","message":"%s","timestamp":"%s"}\n' "$1" "$(date '+%H:%M:%S')"
    exit 1
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

# Acquire token directly with medium-high priority
acquire_token() {
    local priority="$PRIORITY"  # Medium-high priority for network info
    local max_attempts=$MAX_TOKEN_WAIT
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

# Function to execute AT command with direct output capture
execute_at_command() {
    local CMD="$1"
    local OUTPUT_FILE="$TEMP_FILE.cmd.$$"
    
    log_message "Executing command: $CMD" "debug"
    
    # Execute command and redirect output to file for reliable capture
    sms_tool at "$CMD" -t $COMMAND_TIMEOUT > "$OUTPUT_FILE" 2>&1
    local EXIT_CODE=$?
    
    # Read the output regardless of exit code
    if [ -f "$OUTPUT_FILE" ]; then
        local OUTPUT=$(cat "$OUTPUT_FILE")
        rm -f "$OUTPUT_FILE"
        
        if [ -n "$OUTPUT" ]; then
            # We have some output
            if echo "$OUTPUT" | grep -q "CME ERROR"; then
                log_message "Command returned CME ERROR: $OUTPUT" "warn"
                return 1
            elif echo "$OUTPUT" | grep -q "ERROR"; then
                log_message "Command returned ERROR: $OUTPUT" "warn"
                return 1
            else
                # Command produced output that doesn't contain ERROR
                log_message "Command executed successfully with output" "debug"
                echo "$OUTPUT"
                return 0
            fi
        elif [ $EXIT_CODE -eq 0 ]; then
            log_message "Command succeeded but returned empty output" "warn"
            echo "Command returned empty output"
            return 0
        else
            log_message "Command failed with exit code $EXIT_CODE and no output" "error"
            return 1
        fi
    else
        log_message "Failed to create output file" "error"
        return 1
    fi
}

# Function to check network mode from serving cell info
check_network_mode() {
    local OUTPUT="$1"
    
    # Check for both LTE and NR5G-NSA (NSA mode)
    if echo "$OUTPUT" | grep -q "\"LTE\"" && echo "$OUTPUT" | grep -q "\"NR5G-NSA\""; then
        log_message "Detected network mode: NRLTE (NSA)" "info"
        echo "NRLTE"
    # Check for LTE only
    elif echo "$OUTPUT" | grep -q "\"LTE\""; then
        log_message "Detected network mode: LTE" "info"
        echo "LTE"
    # Check for NR5G-SA
    elif echo "$OUTPUT" | grep -q "\"NR5G-SA\""; then
        log_message "Detected network mode: NR5G (SA)" "info"
        echo "NR5G"
    else
        log_message "Detected network mode: UNKNOWN from output: $OUTPUT" "warn"
        echo "UNKNOWN"
    fi
}

# Function to check NR5G measurement info setting
check_nr5g_meas_info() {
    local OUTPUT=$(execute_at_command "AT+QNWCFG=\"nr5g_meas_info\"")
    local EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 0 ] && echo "$OUTPUT" | grep -q "\"nr5g_meas_info\",1"; then
        log_message "NR5G measurement info is enabled" "debug"
        return 0
    else
        log_message "NR5G measurement info is disabled or check failed" "debug"
        return 1
    fi
}

# Function to create JSON output safely
format_output_json() {
    local MODE="$1"
    local SERVING_OUTPUT="$2"
    local NEIGHBOR_OUTPUT="$3"
    local MEAS_OUTPUT="$4"
    
    # Basic JSON structure - start
    printf '{"status":"success","timestamp":"%s","mode":"%s"' "$(date '+%H:%M:%S')" "$MODE"
    
    # Add raw data section
    printf ',"raw_data":{'
    
    # Add serving cell output (always present)
    printf '"servingCell":%s' "$(printf '%s' "$SERVING_OUTPUT" | jq -R -s '.')"
    
    # Add neighbor cells output if available
    if [ -n "$NEIGHBOR_OUTPUT" ]; then
        printf ',"neighborCells":%s' "$(printf '%s' "$NEIGHBOR_OUTPUT" | jq -R -s '.')"
    fi
    
    # Add measurement info output if available
    if [ -n "$MEAS_OUTPUT" ]; then
        printf ',"meas":%s' "$(printf '%s' "$MEAS_OUTPUT" | jq -R -s '.')"
    fi
    
    # Close raw data section
    printf '}'
    
    # Close the whole JSON object
    printf '}\n'
}

# Set up trap for cleanup
trap 'log_message "Script interrupted, cleaning up" "warn"; release_token; rm -f "$TEMP_FILE" "$TEMP_FILE.cmd."*; exit 1' INT TERM EXIT

# Main execution
{
    # Ensure directories exist
    mkdir -p "$QUEUE_DIR" "$RESULTS_DIR"
    
    log_message "Starting network info collection" "info"
    
    # Acquire token for AT command execution before any output
    if ! acquire_token; then
        output_error "Failed to acquire token for command processing"
    fi
    
    # Get the serving cell information first
    log_message "Getting serving cell information" "info"
    SERVING_OUTPUT=$(execute_at_command "AT+QENG=\"servingcell\"")
    EXIT_CODE=$?
    
    # Check if we got valid serving cell info
    if [ $EXIT_CODE -ne 0 ] || [ -z "$SERVING_OUTPUT" ]; then
        log_message "Failed to get serving cell information, output: $SERVING_OUTPUT" "error"
        release_token
        output_error "Failed to get serving cell information"
    fi
    
    log_message "Successfully got serving cell information" "info"
    
    # Determine network mode from serving cell output
    NETWORK_MODE=$(check_network_mode "$SERVING_OUTPUT")
    
    NEIGHBOR_OUTPUT=""
    MEAS_OUTPUT=""
    
    case "$NETWORK_MODE" in
        "NRLTE")
            log_message "Processing NRLTE mode commands" "info"
            NEIGHBOR_OUTPUT=$(execute_at_command "AT+QENG=\"neighbourcell\"")
            
            # Try to get measurement info
            if ! check_nr5g_meas_info; then
                log_message "Enabling NR5G measurement info" "info"
                execute_at_command "AT+QNWCFG=\"nr5g_meas_info\",1" > /dev/null
                sleep 1  # Give it time to take effect
            fi
            
            log_message "Fetching NR5G measurement info" "info"
            MEAS_OUTPUT=$(execute_at_command "AT+QNWCFG=\"nr5g_meas_info\"")
            ;;
        "LTE")
            log_message "Processing LTE mode commands" "info"
            NEIGHBOR_OUTPUT=$(execute_at_command "AT+QENG=\"neighbourcell\"")
            ;;
        "NR5G")
            log_message "Processing NR5G mode commands" "info"
            
            # Try to get measurement info
            if ! check_nr5g_meas_info; then
                log_message "Enabling NR5G measurement info" "info"
                execute_at_command "AT+QNWCFG=\"nr5g_meas_info\",1" > /dev/null
                sleep 1  # Give it time to take effect
            fi
            
            log_message "Fetching NR5G measurement info" "info"
            MEAS_OUTPUT=$(execute_at_command "AT+QNWCFG=\"nr5g_meas_info\"")
            ;;
        *)
            # Even if we don't recognize the mode, we'll still return the serving cell info
            log_message "Unknown network mode, only returning serving cell info" "warn"
            ;;
    esac
    
    # Format and output JSON response
    log_message "Formatting JSON response" "info"
    format_output_json "$NETWORK_MODE" "$SERVING_OUTPUT" "$NEIGHBOR_OUTPUT" "$MEAS_OUTPUT"
    
    # Release token and clean up
    release_token
    rm -f "$TEMP_FILE" "$TEMP_FILE.cmd."*
    
    log_message "Network info collection completed" "info"
    
} || {
    # Error handler
    log_message "Script failed with error" "error"
    release_token
    rm -f "$TEMP_FILE" "$TEMP_FILE.cmd."*
    output_error "Internal error occurred"
}