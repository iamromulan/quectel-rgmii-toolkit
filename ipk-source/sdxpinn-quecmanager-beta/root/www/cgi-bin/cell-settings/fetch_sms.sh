#!/bin/sh
# handle_sms.sh - CGI script to handle SMS web requests
# Content type declaration for CGI
echo "Content-type: application/json"
echo ""

# Check if atinout and jq are installed
if ! command -v atinout &> /dev/null || ! command -v jq &> /dev/null; then
    echo '{"error": "Required tools (atinout or jq) are not installed"}'
    exit 1
fi

# Check if the device exists
if [ ! -c "/dev/smd7" ]; then
    echo '{"error": "Device /dev/smd7 not found"}'
    exit 1
fi

# # Fetch all SMS messages and update the JSON file
# Disabled until the atinout bug is fixed
# if ! echo "AT+CMGL=\"ALL\"" | atinout - /dev/smd7 - | jq -R -s '
#     split("\n") |
#     map(select(length > 0)) |
#     map(
#         select(startswith("+CMGL:") or (. != "OK" and . != "ERROR"))
#     ) |
#     {messages: .}
# ' > /tmp/sms_inbox.json; then
#     echo '{"error": "Failed to fetch SMS messages"}'
#     exit 1
# fi

# Return the contents of the JSON file
if [ -f "/tmp/sms_inbox.json" ]; then
    cat /tmp/sms_inbox.json
else
    echo '{"error": "SMS inbox file not found"}'
fi