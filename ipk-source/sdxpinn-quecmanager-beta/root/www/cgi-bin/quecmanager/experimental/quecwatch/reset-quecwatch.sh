#!/bin/sh

# Set headers for JSON response
echo "Content-type: application/json"
echo ""

# Function to log message
log_message() {
    local level="$1"
    local message="$2"
    local LOG_DIR="/tmp/log/quecwatch"
    local LOG_FILE="${LOG_DIR}/quecwatch.log"
    
    # Ensure log directory exists
    mkdir -p "${LOG_DIR}"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} - [${level}] ${message}" >> "$LOG_FILE"
    logger -t quecwatch "${level}: ${message}"
}

# Reset retry counter
if uci -q get quecmanager.quecwatch >/dev/null; then
    # Reset retry counter in UCI
    uci set quecmanager.quecwatch.current_retries='0'
    
    # Make sure service is enabled
    uci set quecmanager.quecwatch.enabled='1'
    
    # Commit changes
    if uci commit quecmanager; then
        log_message "INFO" "Retry counter reset to 0 and service enabled"
        
        # Also update the retry count file for immediate effect
        echo "0" > "/tmp/quecwatch_retry_count"
        chmod 644 "/tmp/quecwatch_retry_count"
        
        # Restart the service if it exists
        if [ -x "/etc/init.d/quecwatch" ]; then
            if /etc/init.d/quecwatch restart; then
                log_message "INFO" "Service restarted successfully"
                echo '{"status":"success","message":"Retry counter reset and service restarted successfully"}'
            else
                log_message "ERROR" "Failed to restart service"
                echo '{"status":"warning","message":"Retry counter reset but failed to restart service"}'
            fi
        else
            log_message "ERROR" "Service init script not found"
            echo '{"status":"warning","message":"Retry counter reset but service init script not found"}'
        fi
    else
        log_message "ERROR" "Failed to update configuration"
        echo '{"status":"error","message":"Failed to update configuration"}'
    fi
else
    echo '{"status":"error","message":"QuecWatch configuration not found"}'
fi