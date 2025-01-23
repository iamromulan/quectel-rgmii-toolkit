#!/bin/sh

# Set content type to JSON
echo "Content-type: application/json"
echo ""

# Configuration
JSON_FILE="/www/cgi-bin/mcc-mnc-list.json"

# Function to log messages
log_message() {
    logger -t fetch_mccmnc "$1"
}

# Function to output JSON response
output_json() {
    local status="$1"
    local message="$2"
    printf '{"status":"%s","message":"%s"}\n' "$status" "$message"
    exit 1
}

# Main execution
{
    # Check if file exists
    if [ ! -f "$JSON_FILE" ]; then
        log_message "MCC-MNC list file not found"
        output_json "error" "MCC-MNC list file not found"
    fi

    # Read and output the file
    cat "$JSON_FILE" 2>/dev/null || {
        log_message "Failed to read MCC-MNC list file"
        output_json "error" "Failed to read MCC-MNC list file"
    }
} || {
    # Error handler
    log_message "Script failed with error"
    output_json "error" "Internal error occurred"
}