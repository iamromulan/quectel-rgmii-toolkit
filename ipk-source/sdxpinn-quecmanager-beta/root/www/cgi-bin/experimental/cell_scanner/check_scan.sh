#!/bin/sh

# Set content type to JSON
echo "Content-type: application/json"
echo ""

# Configuration
RESULT_FILE="/tmp/qscan_result.json"
PID_FILE="/tmp/cell_scan.pid"

# Function to output JSON response
output_json() {
    local status="$1"
    local message="$2"

    if [ "$status" = "success" ] && [ -f "$RESULT_FILE" ]; then
        # Remove trailing quotes from output field and clean up formatting
        sed 's/"output":""/"output":"/; s/""}/"}/' "$RESULT_FILE"
    else
        printf '{"status":"%s","message":"%s","timestamp":"","output":""}\n' "$status" "$message"
    fi
}

# Check if a scan is already in progress
check_scan_progress() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            output_json "running" "Scan in progress"
            exit 0
        else
            rm -f "$PID_FILE"
        fi
    fi
}

# Check for existing results
check_results() {
    if [ -f "$RESULT_FILE" ]; then
        output_json "success" "Scan results available"
        exit 0
    fi
}

# Main execution
{
    # First check if a scan is in progress
    check_scan_progress

    # Then check for existing results
    check_results

    # If no results and no running scan, indicate idle state
    output_json "idle" "No active scan"
    exit 0
} || {
    # Error handler
    output_json "error" "Failed to check scan status"
    exit 1
}