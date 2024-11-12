#!/bin/sh

# Function to URL-decode the input
urldecode() {
    local data="$1"
    echo -e "$(echo "$data" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;')"
}

# Set content-type for JSON response
echo "Content-type: application/json"
echo ""

# Read the input from POST data
read INPUT_DATA

# Extract the command from the input data (format: command=AT+COMMAND)
RAW_COMMAND=$(echo "$INPUT_DATA" | sed 's/command=//g')

# URL-decode the command
COMMAND=$(urldecode "$RAW_COMMAND")

# Define unique input/output files and AT port
INPUT_FILE="/tmp/custom_input_$$.txt"
OUTPUT_FILE="/tmp/custom_output_$$.txt"

# Debug logging
DEBUG_LOG="/tmp/debug.log"
echo "Starting at_handler script at $(date)" > "$DEBUG_LOG"

CONFIG_FILE="/etc/quecManager.conf"
# Check config file
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file not found: $CONFIG_FILE" >> "$DEBUG_LOG"
    echo '{"error": "Config file not found"}'
    exit 1
fi

# Get AT_PORT with debug logging
# Get AT_PORT with debug logging
AT_PORT=$(head -n 2 "$CONFIG_FILE" | tail -n 1 | cut -d'=' -f2 | tr -d ' \n\r' | sed 's|^dev/||')
echo "Raw config line: $(head -n 1 "$CONFIG_FILE")" >> "$DEBUG_LOG"
echo "Extracted AT_PORT: '$AT_PORT'" >> "$DEBUG_LOG"

# List available devices for debugging
ls -l /dev/smd* >> "$DEBUG_LOG" 2>&1

if [ -z "$AT_PORT" ]; then
    echo "AT_PORT is empty" >> "$DEBUG_LOG"
    echo '{"error": "Failed to read AT_PORT from config"}'
    exit 1
fi

# Check if AT_PORT exists
if [ ! -c "/dev/$AT_PORT" ]; then
    echo "AT_PORT device not found: /dev/$AT_PORT" >> "$DEBUG_LOG"
    echo "Available smd devices:" >> "$DEBUG_LOG"
    ls -l /dev/smd* >> "$DEBUG_LOG" 2>&1
    echo '{"error": "AT_PORT device not found"}'
    exit 1
fi

# Write the command directly to the input file
echo "$COMMAND" > "$INPUT_FILE"

# Run the command using atinout
atinout "$INPUT_FILE" "/dev/$AT_PORT" "$OUTPUT_FILE"

# Read the output from output.txt
OUTPUT=$(cat "$OUTPUT_FILE")

# Escape special characters (like newlines and double quotes) for JSON compatibility
ESCAPED_OUTPUT=$(echo "$OUTPUT" | sed ':a;N;$!ba;s/\n/\\n/g; s/"/\\"/g')

# Escape double quotes in the command for JSON compatibility
ESCAPED_COMMAND=$(echo "$COMMAND" | sed 's/"/\\"/g')

# Create the JSON response
JSON_RESPONSE=$(printf "{\"command\":\"%s\",\"output\":\"%s\"}" "$ESCAPED_COMMAND" "$ESCAPED_OUTPUT")

# Log the JSON response to the debug log
echo "$JSON_RESPONSE" >> /tmp/cgi_debug.log

# Return the output as a valid JSON response
echo "$JSON_RESPONSE"

# Clean up temporary files
rm "$INPUT_FILE" "$OUTPUT_FILE"