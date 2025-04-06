#!/bin/sh

# Ensure the script outputs proper CGI headers
echo "Content-Type: application/json"
echo ""

# Directory where JSON files are stored (adjust as needed)
JSON_DIR="/www/signal_graphs/"

# Function to safely read JSON file
read_json_file() {
    local file="$1"
    if [ -f "$file" ]; then
        cat "$file"
    else
        echo "[]"  # Return empty array if file doesn't exist
    fi
}

# Collect signal metrics from JSON files
RSRP=$(read_json_file "${JSON_DIR}/rsrp.json")
RSRQ=$(read_json_file "${JSON_DIR}/rsrq.json")
SINR=$(read_json_file "${JSON_DIR}/sinr.json")

# Combine metrics into a single JSON object
printf '{
    "rsrp": %s,
    "rsrq": %s,
    "sinr": %s
}' "$RSRP" "$RSRQ" "$SINR"