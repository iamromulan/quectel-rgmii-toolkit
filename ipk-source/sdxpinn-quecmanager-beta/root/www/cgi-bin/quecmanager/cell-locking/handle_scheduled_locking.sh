#!/bin/sh

# Set content type to JSON
echo "Content-type: application/json"
echo ""

# Configuration
UCI_CONFIG="quecmanager"
STATUS_FILE="/tmp/cell_lock_status.json"
LOG_DIR="/tmp/log/cell_lock"
LOG_FILE="$LOG_DIR/cell_lock.log"
SCRIPTS_DIR="/www/cgi-bin/quecmanager/cell-locking"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Function to log messages
log_message() {
    local message="$1"
    local level="${2:-info}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Log to system log
    logger -t cell_lock_handler -p "daemon.$level" "$message"
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

# Function to store cell lock parameters from current settings
store_lock_params() {
    # Get the current LTE lock status
    local lte_cmd="AT+QNWLOCK=\"common/4g\""
    local lte_output=$(sms_tool at "$lte_cmd" -t 5 2>&1)
    if [ $? -eq 0 ]; then
        # Extract parameters if locked
        if ! echo "$lte_output" | grep -q '"common/4g",0'; then
            local lte_params=$(echo "$lte_output" | grep -o '"common/4g",[^[:space:]]*' | cut -d',' -f2-)
            uci set "$UCI_CONFIG.cell_lock.lte_lock=$lte_params"
            log_message "Stored LTE lock params: $lte_params" "info"
        else
            # If not locked, clear the parameters
            uci set "$UCI_CONFIG.cell_lock.lte_lock="
            log_message "No active LTE lock, cleared parameters" "info"
        fi
    fi
    
    # Get the current NR5G lock status
    local nr5g_cmd="AT+QNWLOCK=\"common/5g\""
    local nr5g_output=$(sms_tool at "$nr5g_cmd" -t 5 2>&1)
    if [ $? -eq 0 ]; then
        # Extract parameters if locked
        if ! echo "$nr5g_output" | grep -q '"common/5g",0'; then
            local nr5g_params=$(echo "$nr5g_output" | grep -o '"common/5g",[^[:space:]]*' | cut -d',' -f2-)
            uci set "$UCI_CONFIG.cell_lock.nr5g_lock=$nr5g_params"
            log_message "Stored NR5G lock params: $nr5g_params" "info"
        else
            # If not locked, clear the parameters
            uci set "$UCI_CONFIG.cell_lock.nr5g_lock="
            log_message "No active NR5G lock, cleared parameters" "info"
        fi
    fi
    
    # Get the persist settings
    local persist_cmd="AT+QNWLOCK=\"save_ctrl\""
    local persist_output=$(sms_tool at "$persist_cmd" -t 5 2>&1)
    if [ $? -eq 0 ]; then
        # Extract parameters
        local persist_params=$(echo "$persist_output" | grep -o '"save_ctrl",[^[:space:]]*' | cut -d',' -f2-)
        local lte_persist=$(echo "$persist_params" | cut -d',' -f1)
        local nr5g_persist=$(echo "$persist_params" | cut -d',' -f2)
        
        # Save to UCI
        uci set "$UCI_CONFIG.cell_lock.lte_persist=$lte_persist"
        uci set "$UCI_CONFIG.cell_lock.nr5g_persist=$nr5g_persist"
        log_message "Stored persist settings: LTE=$lte_persist, NR5G=$nr5g_persist" "info"
    fi
    
    # Commit changes
    uci commit "$UCI_CONFIG"
    
    return 0
}

# Function to update crontab
update_crontab() {
    local enabled=$(uci -q get "$UCI_CONFIG.cell_lock.enabled")
    local start_time=$(uci -q get "$UCI_CONFIG.cell_lock.start_time")
    local end_time=$(uci -q get "$UCI_CONFIG.cell_lock.end_time")
    
    if [ -z "$start_time" ] || [ -z "$end_time" ]; then
        log_message "Missing start or end time" "error"
        return 1
    fi
    
    local start_hour=$(echo "$start_time" | cut -d':' -f1 | sed 's/^0//')
    local start_min=$(echo "$start_time" | cut -d':' -f2 | sed 's/^0//')
    local end_hour=$(echo "$end_time" | cut -d':' -f1 | sed 's/^0//')
    local end_min=$(echo "$end_time" | cut -d':' -f2 | sed 's/^0//')
    
    # Create new crontab excluding our entries
    local new_crontab=$(crontab -l | grep -v "apply_lock.sh\|remove_lock.sh")
    
    if [ "$enabled" = "1" ]; then
        # Add our entries
        new_crontab="$new_crontab
$start_min $start_hour * * * $SCRIPTS_DIR/apply_lock.sh
$end_min $end_hour * * * $SCRIPTS_DIR/remove_lock.sh"
    fi
    
    # Apply new crontab
    echo "$new_crontab" | crontab -
    log_message "Updated crontab with start=$start_time, end=$end_time" "info"
    
    return 0
}

# Handle GET requests for status
if [ "$REQUEST_METHOD" = "GET" ]; then
    log_message "Handling GET request for cell lock status" "debug"
    
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
    log_message "Handling POST request for cell lock scheduling" "debug"
    
    # Read POST data
    CONTENT_LENGTH=${CONTENT_LENGTH:-0}
    if [ $CONTENT_LENGTH -gt 0 ]; then
        POST_DATA=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null)
    else
        POST_DATA=""
    fi
    
    # Try to parse JSON data
    if [ -n "$POST_DATA" ] && command -v jsonfilter >/dev/null 2>&1; then
        log_message "Parsing JSON data: $POST_DATA" "debug"
        
        # Extract values from JSON
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
            
            # Store current cell lock parameters before enabling scheduler
            store_lock_params
            
            # Update configuration
            log_message "Enabling scheduling with start=$START_TIME, end=$END_TIME" "info"
            uci -q set "$UCI_CONFIG.cell_lock=scheduler"
            uci set "$UCI_CONFIG.cell_lock.enabled=1"
            uci set "$UCI_CONFIG.cell_lock.start_time=$START_TIME"
            uci set "$UCI_CONFIG.cell_lock.end_time=$END_TIME"
            uci commit "$UCI_CONFIG"
            
            # Update crontab
            update_crontab
            
            # Check if currently in window and apply lock if needed
            CURRENT_TIME=$(date "+%H:%M")
            CURRENT_HOUR=$(echo "$CURRENT_TIME" | cut -d':' -f1 | sed 's/^0//')
            CURRENT_MIN=$(echo "$CURRENT_TIME" | cut -d':' -f2 | sed 's/^0//')
            START_HOUR=$(echo "$START_TIME" | cut -d':' -f1 | sed 's/^0//')
            START_MIN=$(echo "$START_TIME" | cut -d':' -f2 | sed 's/^0//')
            END_HOUR=$(echo "$END_TIME" | cut -d':' -f1 | sed 's/^0//')
            END_MIN=$(echo "$END_TIME" | cut -d':' -f2 | sed 's/^0//')
            
            # Convert to minutes for comparison
            CURRENT_MINUTES=$((CURRENT_HOUR * 60 + CURRENT_MIN))
            START_MINUTES=$((START_HOUR * 60 + START_MIN))
            END_MINUTES=$((END_HOUR * 60 + END_MIN))
            
            # Check if current time is in range
            IN_RANGE=0
            if [ $END_MINUTES -lt $START_MINUTES ]; then
                # Overnight schedule
                if [ $CURRENT_MINUTES -ge $START_MINUTES ] || [ $CURRENT_MINUTES -lt $END_MINUTES ]; then
                    IN_RANGE=1
                fi
            else
                # Same day schedule
                if [ $CURRENT_MINUTES -ge $START_MINUTES ] && [ $CURRENT_MINUTES -lt $END_MINUTES ]; then
                    IN_RANGE=1
                fi
            fi
            
            # Apply lock if in range
            if [ $IN_RANGE -eq 1 ]; then
                log_message "Current time is within scheduled window, applying lock now" "info"
                "$SCRIPTS_DIR/apply_lock.sh" &
            else
                log_message "Current time is outside scheduled window, will apply at scheduled time" "info"
            fi
            
            echo "{\"status\":\"success\",\"message\":\"Scheduling enabled\",\"startTime\":\"$START_TIME\",\"endTime\":\"$END_TIME\"}"
            log_message "Successfully enabled scheduling" "info"
        else
            # Disable scheduling
            log_message "Disabling scheduling" "info"
            uci -q set "$UCI_CONFIG.cell_lock=scheduler"
            uci set "$UCI_CONFIG.cell_lock.enabled=0"
            uci set "$UCI_CONFIG.cell_lock.active=0"
            uci commit "$UCI_CONFIG"
            
            # Update crontab (removes entries)
            update_crontab
            
            # Remove any active locks
            "$SCRIPTS_DIR/remove_lock.sh" &
            
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