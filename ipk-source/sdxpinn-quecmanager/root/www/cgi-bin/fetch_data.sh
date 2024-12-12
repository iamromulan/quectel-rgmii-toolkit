#!/bin/sh

# Set content-type for JSON response
echo "Content-type: application/json"
echo ""

# Function to output error in JSON format
output_error() {
    echo "{\"error\": \"$1\"}"
    exit 1
}

# Define command sets
define_command_sets() {
    COMMAND_SET_1='AT+QUIMSLOT? AT+CNUM AT+COPS? AT+CIMI AT+ICCID AT+CGSN AT+CPIN? AT+CGDCONT? AT+CREG? AT+CFUN? AT+QENG="servingcell" AT+QTEMP AT+CGCONTRDP AT+QCAINFO AT+QRSRP AT+QMAP="WWAN" AT+C5GREG=2;+C5GREG? AT+CGREG=2;+CGREG? AT+QRSRQ AT+QSINR'
    
    COMMAND_SET_2='AT+CGDCONT? AT+CGCONTRDP AT+QNWPREFCFG="mode_pref" AT+QNWPREFCFG="nr5g_disable_mode" AT+QUIMSLOT?'
    
    COMMAND_SET_3='AT+CGMI AT+CGMM AT+QGMR AT+CNUM AT+CIMI AT+ICCID AT+CGSN AT+QMAP="LANIP" AT+QMAP="WWAN" AT+QGETCAPABILITY'
    
    COMMAND_SET_4='AT+QMAP="MPDN_RULE" AT+QMAP="DHCPV4DNS" AT+QCFG="usbnet"'
    
    COMMAND_SET_5='AT+QRSRP AT+QRSRQ AT+QSINR AT+QCAINFO AT+QSPN'

    COMMAND_SET_6='AT+CEREG=2;+CEREG? AT+C5GREG=2;+C5GREG? AT+CPIN? AT+CGDCONT? AT+CGCONTRDP AT+QMAP="WWAN" AT+QRSRP AT+QTEMP AT+QNETRC?'
}

# Define the lock file
LOCK_FILE="/tmp/home_data.lock"

# Acquire the lock (wait if needed)
exec 200>$LOCK_FILE
flock -x 200 || output_error "Unable to acquire lock"

# Temporary files for input/output and AT port
INPUT_FILE="/tmp/input_$$.txt"
OUTPUT_FILE="/tmp/output_$$.txt"

# Debug logging
DEBUG_LOG="/tmp/debug.log"
echo "Starting script at $(date)" > "$DEBUG_LOG"

CONFIG_FILE="/etc/quecManager.conf"
# Check config file
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file not found: $CONFIG_FILE" >> "$DEBUG_LOG"
    output_error "Config file not found"
fi

# Get AT_PORT with debug logging
AT_PORT=$(head -n 1 "$CONFIG_FILE" | cut -d'=' -f2 | tr -d ' \n\r' | sed 's|^dev/||')
echo "Raw config line: $(head -n 1 "$CONFIG_FILE")" >> "$DEBUG_LOG"
echo "Extracted AT_PORT: '$AT_PORT'" >> "$DEBUG_LOG"

if [ -z "$AT_PORT" ]; then
    echo "AT_PORT is empty" >> "$DEBUG_LOG"
    output_error "Failed to read AT_PORT from config"
fi

# Check if AT_PORT exists
if [ ! -c "/dev/$AT_PORT" ]; then
    echo "AT_PORT device not found: /dev/$AT_PORT" >> "$DEBUG_LOG"
    echo "Available smd devices:" >> "$DEBUG_LOG"
    ls -l /dev/smd* >> "$DEBUG_LOG" 2>&1
    output_error "AT_PORT device not found"
fi

# Function to escape JSON strings (handling quotes and newlines)
escape_json() {
    echo "$1" | sed ':a;N;$!ba;s/\n/\\n/g; s/"/\\"/g'
}

# Function to process AT commands
process_commands() {
    local commands="$1"
    local json_response="["
    
    for cmd in $commands; do
        echo "Processing command: $cmd" >> "$DEBUG_LOG"
        
        # Write the command to the input file
        echo "$cmd" > "$INPUT_FILE"
        
        # Run the command using atinout with full path to device
        if ! atinout "$INPUT_FILE" "/dev/$AT_PORT" "$OUTPUT_FILE" 2>> "$DEBUG_LOG"; then
            echo "Command failed: $cmd" >> "$DEBUG_LOG"
            OUTPUT="Error executing command"
        elif [ ! -f "$OUTPUT_FILE" ]; then
            echo "Output file not created for command: $cmd" >> "$DEBUG_LOG"
            OUTPUT="No output file"
        else
            OUTPUT=$(cat "$OUTPUT_FILE" 2>> "$DEBUG_LOG" || echo "Error reading output")
            echo "Command output: $OUTPUT" >> "$DEBUG_LOG"
        fi

        # Escape special characters for JSON
        ESCAPED_OUTPUT=$(escape_json "$OUTPUT")

        # Append the response
        json_response="${json_response}{\"response\":\"$ESCAPED_OUTPUT\"},"
    done

    # Remove the trailing comma and close the JSON array
    if [ "${json_response: -1}" = "," ]; then
        json_response="${json_response%,}]"
    else
        json_response="${json_response}]"
    fi

    echo "$json_response"
}

# Main execution
define_command_sets

# Get command set from query string
COMMAND_SET=$(echo "$QUERY_STRING" | grep -o 'set=[1-6]' | cut -d'=' -f2)

# Select the appropriate command set
case "$COMMAND_SET" in
    1) COMMANDS="$COMMAND_SET_1";;
    2) COMMANDS="$COMMAND_SET_2";;
    3) COMMANDS="$COMMAND_SET_3";;
    4) COMMANDS="$COMMAND_SET_4";;
    5) COMMANDS="$COMMAND_SET_5";;
    6) COMMANDS="$COMMAND_SET_6";;
    *) COMMANDS="$COMMAND_SET_1";; # Default to set 1 if no valid set specified
esac

# Process the selected commands and output the response
JSON_RESPONSE=$(process_commands "$COMMANDS")
echo "$JSON_RESPONSE" >> "$DEBUG_LOG"
echo "$JSON_RESPONSE"

# Clean up temporary files
rm -f "$INPUT_FILE" "$OUTPUT_FILE"

# Release the lock
flock -u 200

echo "Script completed at $(date)" >> "$DEBUG_LOG"