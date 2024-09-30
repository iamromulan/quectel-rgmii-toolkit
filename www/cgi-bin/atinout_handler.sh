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

# Save the command input to at_input.txt
echo "$COMMAND" > /tmp/at_input.txt

# Define the input/output files and AT port
INPUT_FILE="/tmp/input.txt"
OUTPUT_FILE="/tmp/output.txt"
AT_PORT="/dev/smd11"

# Copy the user input to the input file
cp /tmp/at_input.txt "$INPUT_FILE"

# Run the command using atinout
atinout "$INPUT_FILE" "$AT_PORT" "$OUTPUT_FILE"

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