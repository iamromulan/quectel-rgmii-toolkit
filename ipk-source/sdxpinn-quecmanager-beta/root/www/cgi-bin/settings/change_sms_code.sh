#!/bin/sh
# Script for SMS initialization and initial fetch
# Check if atinout and jq are installed
if ! command -v atinout &> /dev/null || ! command -v jq &> /dev/null; then
    echo "Error: Required tools (atinout or jq) are not installed"
    exit 1
fi

# Check if the device exists
if [ ! -c "/dev/smd7" ]; then
    echo "Error: Device /dev/smd7 not found"
    exit 1
fi

# Set SMS text mode
if ! echo "AT+CMGF=1" | atinout - /dev/smd7 -; then
    echo "Error: Failed to set SMS text mode"
    exit 1
fi

# Wait for 2 seconds
sleep 2

# Fetch initial SMS messages
if ! echo "AT+CMGL=\"ALL\"" | atinout - /dev/smd7 - | jq -R -s '
    split("\n") |
    map(select(length > 0)) |
    map(
        select(startswith("+CMGL:") or (. != "OK" and . != "ERROR"))
    ) |
    {messages: .}
' > /tmp/sms_inbox.json; then
    echo "Error: Failed to fetch SMS messages"
    exit 1
fi

echo "SMS initialization completed successfully"