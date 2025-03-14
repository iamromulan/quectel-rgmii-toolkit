#!/bin/sh

# Set content-type for JSON response
echo "Content-type: application/json"
echo ""

# Define paths and constants to match queue system
QUEUE_DIR="/tmp/at_queue"
QUEUE_MANAGER="/www/cgi-bin/services/at_queue_manager"
LOCK_ID="FETCH_DATA_$(date +%s)_$$"
TOKEN_FILE="$QUEUE_DIR/token"

# Logging function (minimized)
log_message() {
    # Only log errors and critical info
    if [ "$1" = "error" ] || [ "$1" = "crit" ]; then
        logger -t at_queue -p "daemon.$1" "$2"
    fi
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

# Acquire token directly (avoid CGI overhead)
acquire_token() {
    local priority="${1:-10}"
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
                rm -f "$TOKEN_FILE" 2>/dev/null
            else
                # Try again
                sleep 0.1
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
            return 0
        fi
        
        sleep 0.1
        attempt=$((attempt + 1))
    done
    
    return 1
}

# Release token directly
release_token() {
    # Only remove if it's our token
    if [ -f "$TOKEN_FILE" ]; then
        local current_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id' 2>/dev/null)
        if [ "$current_holder" = "$LOCK_ID" ]; then
            rm -f "$TOKEN_FILE" 2>/dev/null
        fi
    fi
}

# Direct AT command execution with minimal overhead
execute_at_command() {
    local CMD="$1"
    sms_tool at "$CMD" -t 3 2>/dev/null
}

# Batch process all commands with a single token
process_all_commands() {
    local commands="$1"
    local priority="${2:-10}"
    local first=1
    
    # Acquire a single token for all commands
    if ! acquire_token "$priority"; then
        log_message "error" "Failed to acquire token for batch processing"
        # Return all failed responses
        printf '['
        first=1
        for cmd in $commands; do
            [ $first -eq 0 ] && printf ','
            first=0
            ESCAPED_CMD=$(escape_json "$cmd")
            printf '{"command":"%s","response":"Failed to acquire token","status":"error"}' "${ESCAPED_CMD}"
        done
        printf ']\n'
        return 1
    fi
    
    # Process all commands with the single token
    printf '['
    for cmd in $commands; do
        [ $first -eq 0 ] && printf ','
        first=0
        
        OUTPUT=$(execute_at_command "$cmd")
        local CMD_STATUS=$?
        
        ESCAPED_CMD=$(escape_json "$cmd")
        ESCAPED_OUTPUT=$(escape_json "$OUTPUT")
        
        if [ $CMD_STATUS -eq 0 ] && [ -n "$OUTPUT" ]; then
            printf '{"command":"%s","response":"%s","status":"success"}' \
                "${ESCAPED_CMD}" \
                "${ESCAPED_OUTPUT}"
        else
            printf '{"command":"%s","response":"Command failed","status":"error"}' \
                "${ESCAPED_CMD}"
        fi
    done
    printf ']\n'
    
    # Release token after all commands are done
    release_token
    return 0
}

# Main execution with timeout and proper cleanup
trap 'release_token; exit 1' INT TERM

# Command sets
COMMAND_SET_1='AT+QUIMSLOT? AT+CNUM AT+COPS? AT+CIMI AT+ICCID AT+CGSN AT+CPIN? AT+CGDCONT? AT+CREG? AT+CFUN? AT+QENG="servingcell" AT+QTEMP AT+CGCONTRDP AT+QCAINFO AT+QRSRP AT+QMAP="WWAN" AT+C5GREG=2;+C5GREG? AT+CGREG=2;+CGREG? AT+QRSRQ AT+QSINR'
COMMAND_SET_2='AT+CGDCONT? AT+CGCONTRDP AT+QNWPREFCFG="mode_pref" AT+QNWPREFCFG="nr5g_disable_mode" AT+QUIMSLOT? AT+CFUN?'
COMMAND_SET_3='AT+CGMI AT+CGMM AT+QGMR AT+CNUM AT+CIMI AT+ICCID AT+CGSN AT+QMAP="LANIP" AT+QMAP="WWAN" AT+QGETCAPABILITY'
COMMAND_SET_4='AT+QMAP="MPDN_RULE" AT+QMAP="DHCPV4DNS" AT+QCFG="usbnet"'
COMMAND_SET_5='AT+QRSRP AT+QRSRQ AT+QSINR AT+QCAINFO AT+QSPN'
COMMAND_SET_6='AT+CEREG=2;+CEREG? AT+C5GREG=2;+C5GREG? AT+CPIN? AT+CGDCONT? AT+CGCONTRDP AT+QMAP="WWAN" AT+QRSRP AT+QTEMP AT+QNETRC?'
COMMAND_SET_7='AT+QNWPREFCFG="policy_band" AT+QNWPREFCFG="lte_band";+QNWPREFCFG="nsa_nr5g_band";+QNWPREFCFG="nr5g_band"'
COMMAND_SET_8='AT+QNWLOCK="common/4g" AT+QNWLOCK="common/5g" AT+QNWLOCK="save_ctrl"'

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

# Set priority based on content
PRIORITY=10
if echo "$COMMANDS" | grep -qi "AT+QSCAN"; then
    PRIORITY=1
fi

# Process commands with timeout protection
( sleep 60; kill -TERM $$ 2>/dev/null ) & 
TIMEOUT_PID=$!

process_all_commands "$COMMANDS" "$PRIORITY"

# Clean up
kill $TIMEOUT_PID 2>/dev/null
release_token