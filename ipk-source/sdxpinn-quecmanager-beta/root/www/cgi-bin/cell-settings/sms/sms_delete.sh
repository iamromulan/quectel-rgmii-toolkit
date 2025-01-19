#!/bin/sh

# Set content type
printf "Content-Type: application/json\n\n"

# URL decode function
urldecode() {
    echo "$*" | sed 's/+/ /g;s/%\([0-9A-F][0-9A-F]\)/\\\\x\1/g' | xargs -0 printf '%b'
}

# Extract indexes from query string
query=$(echo "$QUERY_STRING" | grep -o 'indexes=[^&]*' | cut -d= -f2)
indexes=$(urldecode "$query")

# Function to output JSON response
send_json() {
    printf '{"status":"%s","message":"%s"}\n' "$1" "$2"
}

# Validate input
if [ -z "$indexes" ]; then
    send_json "error" "No indexes provided"
    exit 0
fi

# Initialize counters
success=0
failure=0

# Process each index
echo "$indexes" | tr ',' '\n' | while read -r index; do
    if [ -n "$index" ] && [ "$index" -eq "$index" ] 2>/dev/null; then
        if sms_tool delete "$index" 2>/dev/null; then
            success=$((success + 1))
        else
            failure=$((failure + 1))
        fi
    fi
done

# Send response
if [ $success -gt 0 ]; then
    if [ $failure -eq 0 ]; then
        send_json "success" "Successfully deleted $success message(s)"
    else
        send_json "partial" "Deleted $success message(s), failed to delete $failure message(s)"
    fi
else
    send_json "error" "Failed to delete messages"
fi