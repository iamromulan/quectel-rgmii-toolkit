#!/bin/sh

# Set headers for JSON response
echo "Content-type: application/json"
echo ""

# Disable the service in UCI
uci set quecmanager.quecwatch.enabled='0'

if ! uci commit quecmanager; then
    echo '{"status":"error","message":"Failed to update configuration"}'
    exit 1
fi

# Function to log cleanup events
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

# Stop the service
if [ -x "/etc/init.d/quecwatch" ]; then
    if ! /etc/init.d/quecwatch stop; then
        log_message "ERROR" "Failed to stop service cleanly"
        
        # Force kill any remaining processes
        if pkill -f "/www/cgi-bin/services/quecwatch.sh"; then
            log_message "INFO" "Forced termination of QuecWatch processes"
        fi
    else
        log_message "INFO" "Service stopped successfully"
    fi
    
    # Disable the service
    if ! /etc/init.d/quecwatch disable; then
        log_message "WARN" "Failed to disable service"
    else
        log_message "INFO" "Service disabled successfully"
    fi
fi

# Clean up temporary files
for file in "/tmp/quecwatch_status.json" "/tmp/quecwatch_retry_count" "/var/run/quecwatch.pid"; do
    if [ -f "$file" ]; then
        if rm -f "$file"; then
            log_message "INFO" "Removed temporary file: $file"
        else
            log_message "WARN" "Failed to remove temporary file: $file"
        fi
    fi
done

# Return success
echo '{"status":"success","message":"QuecWatch disabled successfully"}'