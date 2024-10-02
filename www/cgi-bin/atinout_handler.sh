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

# Save the command input to a unique at_input file
AT_INPUT_FILE="/tmp/at_input_$$.txt"
echo "$COMMAND" > "$AT_INPUT_FILE"

# Define unique input/output files and AT port
INPUT_FILE="/tmp/input_$$.txt"
OUTPUT_FILE="/tmp/output_$$.txt"
AT_PORT="/dev/smd11"

# Ensure exclusive access to the AT port to avoid overloading smd11
(
    flock -x 200

    # Copy the user input to the input file
    cp "$AT_INPUT_FILE" "$INPUT_FILE"

    # Run the command using atinout
    atinout "$INPUT_FILE" "$AT_PORT" "$OUTPUT_FILE"
) 200>/tmp/atinout.lock

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
rm "$AT_INPUT_FILE" "$INPUT_FILE" "$OUTPUT_FILE"
