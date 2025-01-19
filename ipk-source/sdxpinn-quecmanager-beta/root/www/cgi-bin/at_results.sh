#!/bin/sh
echo "Content-type: application/json"
echo "Access-Control-Allow-Origin: *"
echo "Access-Control-Allow-Methods: GET, POST, OPTIONS"
echo "Access-Control-Allow-Headers: Content-Type"
echo ""

# Configuration
RESULT_FILE="/tmp/at_results.json"
LOG_FILE="/var/log/at_commands.log"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
}

# Function to return error response
send_error() {
    local message="$1"
    jq -n \
        --arg msg "${message}" \
        --arg time "$(date '+%H:%M:%S')" \
        '{
            status: "error",
            message: $msg,
            timestamp: $time
        }'
    exit 1
}

# Parse query parameters
eval $(echo "${QUERY_STRING}" | tr '&' '\n' | sed 's/\([^=]*\)=\([^=]*\)/\1="\2"/')

# Check if results file exists
if [ ! -f "${RESULT_FILE}" ]; then
    send_error "No results found"
fi

# Validate results file contains valid JSON
if ! cat "${RESULT_FILE}" | jq . >/dev/null 2>&1; then
    log_message "Invalid JSON in results file"
    send_error "Invalid results data"
fi

# Handle different query types
case "${action}" in
    "get_by_id")
        # Fetch specific result by ID
        if [ -z "${id}" ]; then
            send_error "No ID provided"
        fi
        
        result=$(cat "${RESULT_FILE}" | jq --arg id "${id}" '. | map(select(.id == $id)) | .[0]')
        
        if [ "${result}" = "null" ]; then
            send_error "No result found for ID: ${id}"
        else
            echo "${result}"
        fi
        ;;
        
    "get_latest")
        # Fetch the most recent N results (default to 10)
        limit=${limit:-10}
        cat "${RESULT_FILE}" | jq --arg limit "${limit}" 'reverse | limit(($limit|tonumber); .)'
        ;;
        
    "get_by_status")
        # Fetch results by status
        if [ -z "${status}" ]; then
            send_error "No status provided"
        fi
        
        cat "${RESULT_FILE}" | jq --arg status "${status}" '. | map(select(.status == $status))'
        ;;
        
    "clear")
        # Clear all results (optional)
        if [ "${confirm}" = "true" ]; then
            echo "[]" > "${RESULT_FILE}"
            jq -n \
                --arg time "$(date '+%H:%M:%S')" \
                '{
                    status: "success",
                    message: "Results cleared",
                    timestamp: $time
                }'
        else
            send_error "Confirmation required to clear results"
        fi
        ;;
        
    *)
        # Default: return all results
        cat "${RESULT_FILE}"
        ;;
esac