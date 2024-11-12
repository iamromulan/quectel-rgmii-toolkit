#!/bin/sh

# Set content type for JSON response
echo "Content-Type: application/json"
echo ""

# Check if the file exists
if [ -f "/etc/config/atcommands.user" ]; then
    # Start JSON object
    printf "{\n"
    awk -F';' '
        BEGIN { first = 1 }
        {
            gsub(/\r/, "", $0)
            if (!first) printf ",\n  "
            else printf "  "
            gsub(/"/, "\\\"", $1)
            gsub(/"/, "\\\"", $2)
            printf "\"%s\": \"%s\"", $1, $2
            first = 0
        }
    ' /etc/config/atcommands.user
    printf "\n}"
else
    echo '{"error": "No Data"}'
fi