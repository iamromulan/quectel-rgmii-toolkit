#!/bin/sh
# AT Queue Client for OpenWRT
# Located in /www/cgi-bin/services/at_queue_client

QUEUE_DIR="/tmp/at_queue"
RESULTS_DIR="$QUEUE_DIR/results"
QUEUE_MANAGER="/www/cgi-bin/services/at_queue_manager.sh"
POLL_INTERVAL=0.01

usage() {
    echo "Usage: $0 [options] <AT command>"
    echo "Options:"
    echo "  -w    Wait for command completion"
    echo "  -t    Timeout in seconds (default: 240)"
    echo "  -h    Show this help message"
    exit 1
}

# Output JSON response
output_json() {
    local content="$1"
    local headers="${2:-1}"  # Default to showing headers
    echo "$content"
}

# URL decode function
urldecode() {
    local encoded="$1"
    logger -t at_queue -p daemon.debug "urldecode: input='$encoded'"
    
    # Handle %2B -> + and %22 -> " conversions
    local decoded="${encoded//%2B/+}"
    decoded="${decoded//%22/\"}"
    # Then handle other encoded characters
    decoded=$(printf '%b' "${decoded//%/\\x}")
    
    logger -t at_queue -p daemon.debug "urldecode: output='$decoded'"
    echo "$decoded"
}

# Extract command ID from response with improved error handling
get_command_id() {
    local response="$1"
    echo "DEBUG: Raw response: '$response'" >&2
    
    # Strip any headers from response
    local json_response=$(echo "$response" | sed -n '/^{/,$p')
    echo "DEBUG: JSON portion: '$json_response'" >&2
    
    # Try to extract command_id using grep and sed instead of jsonfilter
    local cmd_id=$(echo "$json_response" | grep -o '"command_id":"[^"]*"' | sed 's/"command_id":"//;s/"$//')
    
    if [ -n "$cmd_id" ]; then
        echo "$cmd_id"
        return 0
    fi
    
    # Fallback to jsonfilter if available
    echo "DEBUG: Trying jsonfilter as fallback" >&2
    local cmd_id_jsonfilter=$(echo "$json_response" | jsonfilter -e '@.command_id' 2>/dev/null)
    
    if [ -n "$cmd_id_jsonfilter" ]; then
        echo "$cmd_id_jsonfilter"
        return 0
    fi
    
    echo "ERROR: Failed to extract command ID from response" >&2
    return 1
}

# Normalize AT command
normalize_at_command() {
    local cmd="$1"
    logger -t at_queue -p daemon.debug "normalize: input='$cmd'"
    
    # URL decode the command
    cmd=$(urldecode "$cmd")
    logger -t at_queue -p daemon.debug "normalize: after urldecode='$cmd'"
    
    # Remove any carriage returns or newlines
    cmd=$(echo "$cmd" | tr -d '\r\n')
    logger -t at_queue -p daemon.debug "normalize: after cleanup='$cmd'"
    
    # Trim leading/trailing whitespace while preserving quotes
    cmd=$(echo "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    logger -t at_queue -p daemon.debug "normalize: final output='$cmd'"
    
    echo "$cmd"
}

# Submit command with priority handling
submit_command() {
    local cmd="$1"
    local priority=10
    
    # Set high priority for QSCAN commands for faster processing
    if echo "$cmd" | grep -qi "AT+QSCAN"; then
        priority=1
    fi
    
    # Submit using appropriate method
    if [ "${SCRIPT_NAME}" != "" ]; then
        # CGI mode - direct execution
        local escaped_cmd=$(echo "$cmd" | sed 's/"/\\"/g')
        QUERY_STRING="action=enqueue&command=${escaped_cmd}&priority=$priority" "$QUEUE_MANAGER"
    else
        # CLI mode
        "$QUEUE_MANAGER" enqueue "$cmd" "$priority"
    fi
}

# Check if result exists with proper error handling
check_result() {
    local cmd_id="$1"
    local show_headers="${2:-1}"  # Add parameter for header control
    
    if [ -f "$RESULTS_DIR/$cmd_id.json" ]; then
        local result_content=$(cat "$RESULTS_DIR/$cmd_id.json")
        if [ -z "$result_content" ]; then
            logger -t at_queue -p daemon.error "Empty result file for command ID: $cmd_id"
            local error_json="{\"error\":\"Empty result file\",\"command_id\":\"$cmd_id\"}"
            output_json "$error_json" "$show_headers"
            return 1
        fi
        output_json "$result_content" "$show_headers"
        return 0
    fi
    local error_json="{\"error\":\"Result not found\",\"command_id\":\"$cmd_id\"}"
    output_json "$error_json" "$show_headers"
    return 1
}

# Wait for command completion with optimized polling and better error handling
wait_for_completion() {
    local cmd_id="$1"
    local timeout="$2"
    local show_headers="${3:-1}"
    local result_file="$RESULTS_DIR/$cmd_id.json"
    
    if [ -z "$cmd_id" ]; then
        local error_json="{\"error\":\"Invalid command ID\"}"
        output_json "$error_json" "$show_headers"
        return 1
    fi
    
    # First quick check
    if [ -f "$result_file" ]; then
        output_json "$(cat "$result_file")" "$show_headers"
        return 0
    fi
    
    # Wait with shorter polling interval
    local start_time=$(date +%s)
    local current_time
    
    while true; do
        if [ -f "$result_file" ]; then
            output_json "$(cat "$result_file")" "$show_headers"
            return 0
        fi
        
        current_time=$(date +%s)
        if [ $((current_time - start_time)) -ge "$timeout" ]; then
            break
        fi
        
        sleep $POLL_INTERVAL
    done
    
    local error_json=$(cat << EOF
{
    "error": "Timeout waiting for completion",
    "command_id": "$cmd_id",
    "timeout": $timeout
}
EOF
)
    output_json "$error_json" "$show_headers"
    return 1
}

# CGI request handling
if [ "${SCRIPT_NAME}" != "" ]; then
    # Output headers only once at the beginning
    echo "Content-Type: application/json"
    echo ""
    
    # Parse query string
    eval $(echo "$QUERY_STRING" | sed 's/&/;/g')
    
    # Handle different actions
    if [ -n "$command_id" ]; then
        # Get result for specific command ID
        check_result "$command_id" "0"  # Don't show headers
    elif [ -n "$command" ]; then
        # URL decode and normalize the command
        command=$(urldecode "$command")
        command=$(normalize_at_command "$command")
        
        # Check if it's a valid AT command
        if echo "$command" | grep -qi "^AT"; then
            # Submit command and get response
            response=$(submit_command "$command")
            cmd_id=$(get_command_id "$response")
            
            if [ "$wait" = "1" ]; then
                if [ -n "$cmd_id" ]; then
                    wait_for_completion "$cmd_id" "${timeout:-180}" "0"  # Don't show headers
                else
                    output_json "{\"error\":\"Failed to get command ID from response\",\"response\":\"$response\"}" "0"
                fi
            else
                output_json "$response" "0"  # Don't show headers
            fi
        else
            output_json "{\"error\":\"Invalid AT command format\"}" "0"
        fi
    else
        output_json "{\"error\":\"No command or command_id specified\"}" "0"
    fi
    exit 0
fi

# CLI processing
wait_mode=0
timeout=180

while getopts "wt:h" opt; do
    case $opt in
        w) wait_mode=1 ;;
        t) timeout="$OPTARG" ;;
        h) usage ;;
        ?) usage ;;
    esac
done

shift $((OPTIND-1))

if [ $# -eq 0 ]; then
    usage
fi

# Combine remaining arguments into AT command
command="$*"

# Validate AT command format
if ! echo "$command" | grep -qi "^AT"; then
    echo "Error: Command must start with 'AT'"
    exit 1
fi

# Submit command and get response
response=$(submit_command "$command")
cmd_id=$(get_command_id "$response")

if [ -z "$cmd_id" ]; then
    echo "Error: Failed to get command ID"
    echo "Response: $response"
    exit 1
fi

if [ $wait_mode -eq 1 ]; then
    wait_for_completion "$cmd_id" "$timeout"
else
    echo "$response"
fi