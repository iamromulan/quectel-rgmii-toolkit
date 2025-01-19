#!/bin/sh

echo "Content-Type: application/json"
echo "Cache-Control: no-cache"
echo ""

# Function to URL decode the string
urldecode() {
  local url_encoded="${1//+/ }"
  printf '%b' "${url_encoded//%/\\x}"
}

# Function to escape JSON string
escape_json() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g; s/\r/\\r/g; s/\t/\\t/g'
}

# Read POST data
read -r QUERY_STRING

# Extract phone and message from POST data
phone=$(echo "$QUERY_STRING" | grep -o 'phone=[^&]*' | cut -d= -f2)
message=$(echo "$QUERY_STRING" | grep -o 'message=[^&]*' | cut -d= -f2)

# URL decode the message
decoded_message=$(urldecode "$message")

# Validate inputs
if [ -z "$phone" ] || [ -z "$message" ]; then
    echo '{"success":false,"error":"Phone number and message are required"}'
    exit 0
fi

# Validate phone number (only numbers allowed)
if ! echo "$phone" | grep -q '^[0-9]\+$'; then
    echo '{"success":false,"error":"Invalid phone number format"}'
    exit 0
fi

# Try to send SMS and capture output
result=$(sms_tool send "$phone" "$decoded_message" 2>&1)
escaped_result=$(escape_json "$result")

# Check if SMS was sent successfully by looking for "sms sent sucessfully"
if echo "$result" | grep -q "sms sent sucessfully"; then
    # Extract the message ID if present
    message_id=$(echo "$result" | grep -o '[0-9]*$')
    echo "{\"success\":true,\"message\":\"SMS sent successfully\",\"messageId\":\"$message_id\",\"raw\":\"$escaped_result\"}"
elif echo "$result" | grep -q "sms not sent, code 350"; then
    # Kill any hanging sms_tool process
    pkill -f "sms_tool send"
    echo '{"success":false,"error":"No prepaid credit available"}'
else
    # Kill any hanging sms_tool process
    pkill -f "sms_tool send"
    echo "{\"success\":false,\"error\":\"Failed to send SMS\",\"raw\":\"$escaped_result\"}"
fi