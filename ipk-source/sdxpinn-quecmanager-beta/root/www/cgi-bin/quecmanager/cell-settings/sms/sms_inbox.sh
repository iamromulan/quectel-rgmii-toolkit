#!/bin/sh

printf "Content-type: application/json\r\n\r\n"

# Execute the command and return the JSON response
if command -v sms_tool > /dev/null 2>&1; then
    sms_tool -j recv
else
    printf '{"error": "sms_tool not found"}\n'
fi