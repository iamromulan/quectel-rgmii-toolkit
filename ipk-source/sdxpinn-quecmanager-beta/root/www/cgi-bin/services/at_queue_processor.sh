#!/bin/sh

QUEUE_FILE="/tmp/at_pipe.txt"
RESULT_FILE="/tmp/at_results.json"
LOG_FILE="/var/log/at_commands.log"
# Define all lock keywords
FETCH_LOCK_KEYWORD="FETCH_DATA_LOCK"
SIGNAL_LOCK_KEYWORD="SIGNAL_METRICS_LOCK"
# Combine keywords for pattern matching
ALL_LOCK_KEYWORDS="${FETCH_LOCK_KEYWORD}\\|${SIGNAL_LOCK_KEYWORD}"

# Create or clear necessary files
touch "${QUEUE_FILE}"
[ ! -f "${RESULT_FILE}" ] && echo '[]' > "${RESULT_FILE}"

# Log messages to the log file
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_FILE}"
}

# Escape special characters for JSON
escape_json() {
    echo "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g'
}

# Function to check if any lock is present
is_system_locked() {
    grep -q "\"command\":\"\\(${ALL_LOCK_KEYWORDS}\\)\"" "${QUEUE_FILE}"
    return $?
}

# Process a single command
process_command() {
    local command="$1"
    local timestamp="$2"
    local cmd_id="$3"

    log_message "Processing command: ${command} (ID: ${cmd_id})"

    # Check if sms_tool exists and is executable
    if ! which sms_tool >/dev/null 2>&1; then
        log_message "Error: sms_tool not found in PATH"
        result="sms_tool not found"
        exit_code=1
    else
        # Execute the AT command using sms_tool
        result=$(sms_tool at "${command}" 2>&1)
        exit_code=$?
        log_message "Command output: ${result}"
        log_message "Exit code: ${exit_code}"
    fi

    # Escape the command and result for JSON
    escaped_command=$(escape_json "${command}")
    escaped_result=$(echo "${result}" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g' | tr -d '\r')

    # Generate the result JSON
    if [ ${exit_code} -eq 0 ]; then
        log_message "Command successful: ${command}"
        RESULT_JSON=$(printf '{"id":"%s","status":"success","command":"%s","response":"%s","queued_at":"%s","executed_at":"%s"}' \
            "${cmd_id}" "${escaped_command}" "${escaped_result}" "${timestamp}" "$(date '+%H:%M:%S')")
    else
        log_message "Command failed: ${command}"
        RESULT_JSON=$(printf '{"id":"%s","status":"error","command":"%s","error":"%s","queued_at":"%s","executed_at":"%s"}' \
            "${cmd_id}" "${escaped_command}" "${escaped_result}" "${timestamp}" "$(date '+%H:%M:%S')")
    fi

    # Update the results file safely
    if ! current_results=$(cat "${RESULT_FILE}" 2>/dev/null); then
        log_message "Error reading results file, initializing new one"
        echo '[]' > "${RESULT_FILE}"
        current_results='[]'
    fi

    # Append the result JSON to the results file
    if ! echo "${current_results}" | jq --argjson new "${RESULT_JSON}" '. + [$new]' > "${RESULT_FILE}.tmp"; then
        log_message "Error updating results file"
        return 1
    fi

    mv "${RESULT_FILE}.tmp" "${RESULT_FILE}"
    log_message "Successfully updated results file"
    return ${exit_code}
}

# Check if an entry is a lock entry
is_lock_entry() {
    local line="$1"
    echo "${line}" | grep -q "\"command\":\"\\(${ALL_LOCK_KEYWORDS}\\)\""
    return $?
}

# Process pending commands in the queue
process_pending_commands() {
    while true; do
        # Check if any lock is present
        if is_system_locked; then
            local lock_type=$(grep -o "\"command\":\"[^\"]*\"" "${QUEUE_FILE}" | grep "${ALL_LOCK_KEYWORDS}")
            log_message "System is locked: ${lock_type}, waiting..."
            sleep 0.5
            continue
        fi

        # Read the first line from the queue
        line=$(head -n 1 "${QUEUE_FILE}" 2>/dev/null)

        if [ -n "${line}" ]; then
            log_message "Processing queue entry: ${line}"

            # Skip processing if it's a lock entry
            if is_lock_entry "${line}"; then
                log_message "Found lock entry, skipping"
                sed -i '1d' "${QUEUE_FILE}"
                continue
            fi

            # Validate JSON before processing
            if ! echo "${line}" | jq empty 2>/dev/null; then
                log_message "Invalid JSON in queue, skipping line"
                sed -i '1d' "${QUEUE_FILE}"
                continue
            fi

            # Parse the command, timestamp, and ID from the JSON entry
            command=$(echo "${line}" | jq -r '.command // empty')
            timestamp=$(echo "${line}" | jq -r '.timestamp // empty')
            cmd_id=$(echo "${line}" | jq -r '.id // empty')

            if [ -z "${command}" ] || [ -z "${timestamp}" ] || [ -z "${cmd_id}" ]; then
                log_message "Missing required fields in JSON, skipping"
                sed -i '1d' "${QUEUE_FILE}"
                continue
            fi

            # Process the command
            process_command "${command}" "${timestamp}" "${cmd_id}"

            # Remove the processed line from the queue
            sed -i '1d' "${QUEUE_FILE}"

            # Add a small delay between commands
            sleep 0.1
        else
            # No commands in queue, wait briefly before checking again
            sleep 0.5
            break
        fi
    done
}

# Main queue monitoring loop
process_queue() {
    log_message "Starting queue processor with multiple lock support"
    
    while true; do
        # Process any pending commands
        process_pending_commands
        
        # Wait for changes to the queue file
        inotifywait -q -e modify,create "${QUEUE_FILE}" >/dev/null 2>&1
        
        # Small delay to allow file to stabilize
        sleep 0.1
    done
}

# Start processing the queue
log_message "Queue processor started with file monitoring and multiple lock support"
process_queue