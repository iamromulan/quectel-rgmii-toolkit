#!/bin/sh
# CGI header
echo "Content-type: application/json"
echo ""

# Queue file
QUEUE_FILE="/tmp/at_pipe.txt"
RESULT_FILE="/tmp/at_results.json"
LOG_FILE="/var/log/at_commands.log"

# Create queue file if it doesn't exist
touch "${QUEUE_FILE}"

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
}

# Function to generate random ID
generate_random_id() {
    # Combine multiple sources of randomness
    local timestamp=$(date +%s%N)
    local random1=$(head -c 4 /dev/urandom | xxd -p)
    local random2=$(echo $$ $RANDOM | md5sum | head -c 8)
    echo "${timestamp}-${random1}-${random2}"
}

# Function to escape special characters for JSON
escape_json() {
    echo "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g'
}

# Function to decode URL
decode_url() {
    local encoded="$1"
    # First handle percent-encoded characters
    printf '%b' "${encoded}" | sed -e 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g' | xargs -0 echo -e |
    # Then handle plus signs separately (preserve them for AT commands)
    sed 's/[+]/%2B/g' | sed 's/%2B/+/g'
}

# Get command from query string
QUERY_STRING="${QUERY_STRING:-}"
RAW_COMMAND=$(echo "${QUERY_STRING}" | sed 's/^command=//')

if [ -n "${RAW_COMMAND}" ]; then
    # Decode URL-encoded command with fixed plus sign handling
    AT_COMMAND=$(decode_url "${RAW_COMMAND}")
    
    # Generate unique random ID
    CMD_ID=$(generate_random_id)
    
    # Create timestamp
    TIMESTAMP=$(date '+%H:%M:%S')
    
    # Escape command for JSON
    ESCAPED_COMMAND=$(escape_json "${AT_COMMAND}")
    
    # Create JSON entry for queue (all in one line)
    QUEUE_ENTRY=$(printf '{"id":"%s","timestamp":"%s","command":"%s","status":"pending"}\n' \
        "${CMD_ID}" "${TIMESTAMP}" "${ESCAPED_COMMAND}")
    
    # Add to queue file
    echo "${QUEUE_ENTRY}" >> "${QUEUE_FILE}"
    log_message "Queued command: ${AT_COMMAND} with ID: ${CMD_ID}"
    
    # Return immediate response
    printf '{"status":"queued","message":"Command has been queued","command":"%s","id":"%s","queued_at":"%s"}\n' \
        "${ESCAPED_COMMAND}" "${CMD_ID}" "${TIMESTAMP}"
else
    # Return error response
    printf '{"status":"error","message":"No command provided","timestamp":"%s"}\n' "$(date '+%H:%M:%S')"
    exit 1
fi