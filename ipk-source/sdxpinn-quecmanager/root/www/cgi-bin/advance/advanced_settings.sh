#!/bin/sh

# Set content-type for JSON response
echo "Content-type: application/json"
echo ""

# Define the lock file
LOCK_FILE="/tmp/home_data.lock"

# Acquire the lock (wait if needed)
exec 200>$LOCK_FILE
flock -x 200

# Temporary files for input/output and AT port
INPUT_FILE="/tmp/input_$$.txt"
OUTPUT_FILE="/tmp/output_$$.txt"
AT_PORT="/dev/smd11"

# Debug file path
DEBUG_FILE="/tmp/debug-json-result.txt"

# Function to escape JSON strings (handling quotes and newlines)
escape_json() {
    # Escape newlines and double quotes
    echo "$1" | sed ':a;N;$!ba;s/\n/\\n/g; s/"/\\"/g'
}

# Initialize JSON response array
JSON_RESPONSE="["

# List of AT commands to run, one by one
for COMMAND in 'AT+QMAP="MPDN_RULE"' 'AT+QMAP="DHCPV4DNS"' 'AT+QCFG="usbnet"'; do
    # Write the command to the input file
    echo "$COMMAND" > "$INPUT_FILE"

    # Run the command using atinout
    atinout "$INPUT_FILE" "$AT_PORT" "$OUTPUT_FILE"

    # Read the output from the output file
    OUTPUT=$(cat "$OUTPUT_FILE")

    # Escape special characters for JSON (escape only output)
    ESCAPED_OUTPUT=$(escape_json "$OUTPUT")

    # Append the response as an object to the JSON response array
    JSON_RESPONSE="${JSON_RESPONSE}{\"response\":\"$ESCAPED_OUTPUT\"},"
done

# Remove the trailing comma and close the JSON array
if [ "${JSON_RESPONSE: -1}" = "," ]; then
    JSON_RESPONSE="${JSON_RESPONSE%,}]"
else
    JSON_RESPONSE="${JSON_RESPONSE}]"
fi

# Write the JSON response to the debug file for troubleshooting
echo "$JSON_RESPONSE" > "$DEBUG_FILE"

# Return the output as a valid JSON response
echo "$JSON_RESPONSE"

# Clean up temporary files
rm "$INPUT_FILE" "$OUTPUT_FILE"

# Release the lock
flock -u 200