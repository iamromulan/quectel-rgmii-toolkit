#!/bin/sh

# Set content type to JSON
echo "Content-type: application/json"
echo ""

# Configuration
UCI_CONFIG="quecmanager"
STATUS_FILE="/tmp/cell_lock_status.json"
QUEUE_DIR="/tmp/at_queue"
TOKEN_FILE="$QUEUE_DIR/token"
LOG_DIR="/tmp/log/cell_lock"
LOG_FILE="$LOG_DIR/cell_lock.log"
DEBUG_FILE="$LOG_DIR/debug.log"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Function to log messages
log_message() {
    local level="${2:-info}"
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Debug logging
    echo "[$timestamp] [$level] $message" >> "$DEBUG_FILE"
    
    # Log to system log
    logger -t cell_lock -p "daemon.$level" "$message"
}

# Log request details for debugging
log_request_info() {
    echo "==== NEW REQUEST ====" >> "$DEBUG_FILE"
    echo "METHOD: $REQUEST_METHOD" >> "$DEBUG_FILE"
    echo "QUERY_STRING: $QUERY_STRING" >> "$DEBUG_FILE"
    echo "CONTENT_LENGTH: $CONTENT_LENGTH" >> "$DEBUG_FILE"
    echo "CONTENT_TYPE: $CONTENT_TYPE" >> "$DEBUG_FILE"
}

# Function to validate time format (HH:MM)
validate_time_format() {
    local time="$1"
    local name="$2"
    
    if ! echo "$time" | grep -q '^[0-2][0-9]:[0-5][0-9]$'; then
        echo "{\"status\":\"error\",\"message\":\"$name must be in format HH:MM (24-hour)\"}"
        log_message "$name has invalid format: $time" "error"
        return 1
    fi
    
    # Further validate hour (00-23)
    local hour=$(echo "$time" | cut -d':' -f1)
    if [ "$hour" -gt 23 ]; then
        echo "{\"status\":\"error\",\"message\":\"Hour in $name must be between 00-23\"}"
        log_message "$name has invalid hour: $hour" "error"
        return 1
    fi
    
    return 0
}

# Log request info for debugging
log_request_info

# Handle GET requests for status
if [ "$REQUEST_METHOD" = "GET" ]; then
    log_message "Handling GET request" "debug"
    
    # Load UCI configuration
    if [ -f "/etc/config/quecmanager" ]; then
        ENABLED=$(uci -q get "$UCI_CONFIG.cell_lock.enabled" || echo "0")
        START_TIME=$(uci -q get "$UCI_CONFIG.cell_lock.start_time" || echo "")
        END_TIME=$(uci -q get "$UCI_CONFIG.cell_lock.end_time" || echo "")
        ACTIVE=$(uci -q get "$UCI_CONFIG.cell_lock.active" || echo "0")
        
        # Convert to JSON boolean format
        [ "$ENABLED" = "1" ] && ENABLED="true" || ENABLED="false"
        [ "$ACTIVE" = "1" ] && ACTIVE="true" || ACTIVE="false"
        
        # Get current status from status file
        STATUS="disabled"
        MESSAGE="\"Scheduler is disabled\""
        
        if [ -f "$STATUS_FILE" ]; then
            STATUS=$(cat "$STATUS_FILE" | jsonfilter -e '@.status' 2>/dev/null)
            MESSAGE=$(cat "$STATUS_FILE" | jsonfilter -e '@.message' 2>/dev/null)
            if [ -n "$MESSAGE" ]; then
                MESSAGE="\"$MESSAGE\""
            else
                MESSAGE="\"Status not available\""
            fi
        fi
        
        # Output JSON response
        echo "{\"enabled\":$ENABLED,\"start_time\":\"$START_TIME\",\"end_time\":\"$END_TIME\",\"active\":$ACTIVE,\"status\":\"$STATUS\",\"message\":$MESSAGE}"
        log_message "Returned status response" "debug"
    else
        echo "{\"enabled\":false,\"start_time\":\"\",\"end_time\":\"\",\"active\":false,\"status\":\"unknown\",\"message\":\"Configuration not found\"}"
        log_message "No configuration found" "warn"
    fi
    exit 0
fi

# Handle POST requests for enabling/disabling scheduling
if [ "$REQUEST_METHOD" = "POST" ]; then
    log_message "Handling POST request" "debug"
    
    # Read POST data
    CONTENT_LENGTH=${CONTENT_LENGTH:-0}
    if [ $CONTENT_LENGTH -gt 0 ]; then
        POST_DATA=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null)
        echo "POST_DATA: $POST_DATA" >> "$DEBUG_FILE"
    else
        POST_DATA=""
        echo "No POST_DATA (empty)" >> "$DEBUG_FILE"
    fi
    
    # Try to parse JSON data
    if [ -n "$POST_DATA" ] && command -v jsonfilter >/dev/null 2>&1; then
        log_message "Attempting to parse JSON data" "debug"
        
        # Try to extract values from JSON - allow for differently named fields
        ENABLED=$(echo "$POST_DATA" | jsonfilter -e '@.enabled' 2>/dev/null)
        if [ -z "$ENABLED" ]; then
            ENABLED=$(echo "$POST_DATA" | jsonfilter -e '@.enable' 2>/dev/null)
        fi
        
        START_TIME=$(echo "$POST_DATA" | jsonfilter -e '@.startTime' 2>/dev/null)
        if [ -z "$START_TIME" ]; then
            START_TIME=$(echo "$POST_DATA" | jsonfilter -e '@.start_time' 2>/dev/null)
        fi
        
        END_TIME=$(echo "$POST_DATA" | jsonfilter -e '@.endTime' 2>/dev/null)
        if [ -z "$END_TIME" ]; then
            END_TIME=$(echo "$POST_DATA" | jsonfilter -e '@.end_time' 2>/dev/null)
        fi
        
        echo "Parsed JSON: enabled=$ENABLED, start=$START_TIME, end=$END_TIME" >> "$DEBUG_FILE"
        
        # Handle enable/disable logic
        if [ "$ENABLED" = "true" ] || [ "$ENABLED" = "1" ]; then
            # Validate times for enable request
            if [ -z "$START_TIME" ] || [ -z "$END_TIME" ]; then
                echo "{\"status\":\"error\",\"message\":\"Start time and end time are required\"}"
                log_message "Missing start or end time" "error"
                exit 1
            fi
            
            # Validate time formats
            validate_time_format "$START_TIME" "Start time" || exit 1
            validate_time_format "$END_TIME" "End time" || exit 1
            
            # Update configuration
            log_message "Enabling scheduling with start=$START_TIME, end=$END_TIME" "info"
            uci -q set "$UCI_CONFIG.cell_lock=scheduler"
            uci set "$UCI_CONFIG.cell_lock.enabled=1"
            uci set "$UCI_CONFIG.cell_lock.start_time=$START_TIME"
            uci set "$UCI_CONFIG.cell_lock.end_time=$END_TIME"
            uci commit "$UCI_CONFIG"
            
            # Ensure service is running
            if [ -x "/etc/init.d/quecmanager_cell_locking" ]; then
                /etc/init.d/quecmanager_cell_locking enable
                /etc/init.d/quecmanager_cell_locking restart
                log_message "Started scheduler service" "info"
            else
                log_message "Service script not found" "error"
                echo "{\"status\":\"error\",\"message\":\"Service script not found\"}"
                exit 1
            fi
            
            echo "{\"status\":\"success\",\"message\":\"Scheduling enabled\",\"startTime\":\"$START_TIME\",\"endTime\":\"$END_TIME\"}"
            log_message "Successfully enabled scheduling" "info"
        else
            # Disable scheduling
            log_message "Disabling scheduling" "info"
            uci -q set "$UCI_CONFIG.cell_lock=scheduler"
            uci set "$UCI_CONFIG.cell_lock.enabled=0"
            uci commit "$UCI_CONFIG"
            
            # Stop service
            if [ -x "/etc/init.d/quecmanager_cell_locking" ]; then
                /etc/init.d/quecmanager_cell_locking stop
                /etc/init.d/quecmanager_cell_locking disable
                log_message "Stopped scheduler service" "info"
            fi
            
            echo "{\"status\":\"success\",\"message\":\"Scheduling disabled\"}"
            log_message "Successfully disabled scheduling" "info"
        fi
    else
        log_message "Failed to parse JSON data or no JSON data received" "error"
        echo "{\"status\":\"error\",\"message\":\"Invalid request or missing JSON data\"}"
    fi
    exit 0
fi

# If no valid method was handled
echo "{\"status\":\"error\",\"message\":\"Invalid request method\"}"
log_message "Invalid request method: $REQUEST_METHOD" "error"
exit 1