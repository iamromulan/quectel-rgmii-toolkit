#!/bin/sh

# Set content-type for JSON response
echo "Content-type: application/json"
echo ""

# Define file paths and configuration
QUEUE_FILE="/tmp/at_pipe.txt"
LOCK_KEYWORD="FETCH_DATA_LOCK"
CELL_SCAN_KEYWORD="CELL_SCAN"
CELL_SCAN_WAIT=3  # Wait time for cell scan in seconds
MAX_WAIT=6  # Maximum seconds to wait for lock

# Function to output error in JSON format
output_error() {
    printf '{"error": "%s"}\n' "$1"
    exit 1
}

# Function to remove cell scan entries after timeout
remove_cell_scan() {
    local start_time=$(date +%s)
    local has_waited=0

    # Wait for cell scan to complete naturally
    while [ $has_waited -eq 0 ]; do
        if ! grep -q "\"command\":\"$CELL_SCAN_KEYWORD\"" "$QUEUE_FILE"; then
            return 0
        fi

        current_time=$(date +%s)
        if [ $((current_time - start_time)) -ge $CELL_SCAN_WAIT ]; then
            has_waited=1
        else
            sleep 1
        fi
    done

    # After wait period, forcibly remove cell scan entries
    if grep -q "\"command\":\"$CELL_SCAN_KEYWORD\"" "$QUEUE_FILE"; then
        logger -t at_commands "Removing cell scan entry after $CELL_SCAN_WAIT seconds timeout"
        sed -i "/${CELL_SCAN_KEYWORD}/d" "$QUEUE_FILE"
        sync
    fi
}

# Function to clean and add high-priority lock
add_clean_lock() {
    local TIMESTAMP=$(date +%s)
    local WAIT_START=$(date +%s)
    
    # First, handle any cell scan operations
    remove_cell_scan
    
    while true; do
        local CURRENT_TIME=$(date +%s)
        
        # After MAX_WAIT seconds, forcibly remove any existing lock
        if [ $((CURRENT_TIME - WAIT_START)) -ge $MAX_WAIT ]; then
            sed -i "/${LOCK_KEYWORD}/d" "$QUEUE_FILE"
            logger -t at_commands "Removed existing lock after $MAX_WAIT seconds timeout"
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
            logger -t at_commands "High priority lock created by PID $$ at $TIMESTAMP"
            trap 'remove_lock; exit' INT TERM EXIT
            return 0
        fi
        
        if [ $((CURRENT_TIME - WAIT_START)) -lt $MAX_WAIT ]; then
            sleep 1
        else
            logger -t at_commands "Failed to acquire lock after $MAX_WAIT seconds"
            return 1
        fi
    done
}

# Simple remove lock function that only removes our entry
remove_lock() {
    sed -i "/\"pid\":\"$$\"/d" "$QUEUE_FILE"
    logger -t at_commands "Lock removed by PID $$"
}

# Improved JSON string escaping function
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

# Enhanced AT command execution with retries
execute_at_command() {
    local CMD="$1"
    local RETRY_COUNT=0
    local MAX_RETRIES=3
    local OUTPUT=""
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        OUTPUT=$(sms_tool at "$CMD" -t 4 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$OUTPUT" ]; then
            echo "$OUTPUT"
            return 0
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        [ $RETRY_COUNT -lt $MAX_RETRIES ] && sleep 1
    done
    
    logger -t at_commands "Command failed after $MAX_RETRIES attempts: $CMD"
    return 1
}

# Enhanced command processing function
process_commands() {
    local commands="$1"
    local first=1
    
    printf '['
    
    for cmd in $commands; do
        [ $first -eq 0 ] && printf ','
        first=0
        
        OUTPUT=$(execute_at_command "$cmd")
        local CMD_STATUS=$?
        
        ESCAPED_CMD=$(escape_json "$cmd")
        ESCAPED_OUTPUT=$(escape_json "$OUTPUT")
        
        if [ $CMD_STATUS -eq 0 ]; then
            printf '{"command":"%s","response":"%s","status":"success"}' \
                "${ESCAPED_CMD}" \
                "${ESCAPED_OUTPUT}"
        else
            printf '{"command":"%s","response":"Command failed","status":"error"}' \
                "${ESCAPED_CMD}"
        fi
    done
    
    printf ']\n'
}

# Main process wrapper with automatic lock handling
main_with_clean_lock() {
    ( sleep 60; kill -TERM $$ 2>/dev/null ) & 
    TIMEOUT_PID=$!
    
    if ! add_clean_lock; then
        output_error "Failed to acquire lock for command processing"
        kill $TIMEOUT_PID 2>/dev/null
        exit 1
    fi
    
    process_commands "$COMMANDS"
    
    remove_lock
    kill $TIMEOUT_PID 2>/dev/null
}

# Define command sets
define_command_sets() {
    COMMAND_SET_1='AT+QUIMSLOT? AT+CNUM AT+COPS? AT+CIMI AT+ICCID AT+CGSN AT+CPIN? AT+CGDCONT? AT+CREG? AT+CFUN? AT+QENG="servingcell" AT+QTEMP AT+CGCONTRDP AT+QCAINFO AT+QRSRP AT+QMAP="WWAN" AT+C5GREG=2;+C5GREG? AT+CGREG=2;+CGREG? AT+QRSRQ AT+QSINR'
    COMMAND_SET_2='AT+CGDCONT? AT+CGCONTRDP AT+QNWPREFCFG="mode_pref" AT+QNWPREFCFG="nr5g_disable_mode" AT+QUIMSLOT?'
    COMMAND_SET_3='AT+CGMI AT+CGMM AT+QGMR AT+CNUM AT+CIMI AT+ICCID AT+CGSN AT+QMAP="LANIP" AT+QMAP="WWAN" AT+QGETCAPABILITY'
    COMMAND_SET_4='AT+QMAP="MPDN_RULE" AT+QMAP="DHCPV4DNS" AT+QCFG="usbnet"'
    COMMAND_SET_5='AT+QRSRP AT+QRSRQ AT+QSINR AT+QCAINFO AT+QSPN'
    COMMAND_SET_6='AT+CEREG=2;+CEREG? AT+C5GREG=2;+C5GREG? AT+CPIN? AT+CGDCONT? AT+CGCONTRDP AT+QMAP="WWAN" AT+QRSRP AT+QTEMP AT+QNETRC?'
    COMMAND_SET_7='AT+QNWPREFCFG="policy_band" AT+QNWPREFCFG="lte_band";+QNWPREFCFG="nsa_nr5g_band";+QNWPREFCFG="nr5g_band"'
    COMMAND_SET_8='AT+QNWLOCK="common/4g" AT+QNWLOCK="common/5g" AT+QNWLOCK="save_ctrl"'
}

# Main execution
define_command_sets

# Get command set from query string with validation
COMMAND_SET=$(echo "$QUERY_STRING" | grep -o 'set=[1-8]' | cut -d'=' -f2 | tr -cd '0-9')
if [ -z "$COMMAND_SET" ] || [ "$COMMAND_SET" -lt 1 ] || [ "$COMMAND_SET" -gt 8 ]; then
    COMMAND_SET=1
fi

# Select the appropriate command set
case "$COMMAND_SET" in
    1) COMMANDS="$COMMAND_SET_1";;
    2) COMMANDS="$COMMAND_SET_2";;
    3) COMMANDS="$COMMAND_SET_3";;
    4) COMMANDS="$COMMAND_SET_4";;
    5) COMMANDS="$COMMAND_SET_5";;
    6) COMMANDS="$COMMAND_SET_6";;
    7) COMMANDS="$COMMAND_SET_7";;
    8) COMMANDS="$COMMAND_SET_8";;
esac

# Execute main process with clean lock handling
main_with_clean_lock