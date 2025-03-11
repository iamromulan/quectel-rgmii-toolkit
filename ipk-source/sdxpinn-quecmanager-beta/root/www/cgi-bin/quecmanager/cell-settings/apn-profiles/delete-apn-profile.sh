#!/bin/sh

echo "Content-type: application/json"
echo ""

# Initialize error tracking
has_error=false
error_message=""

# Function to append to error message
append_error() {
    if [ -z "$error_message" ]; then
        error_message="$1"
    else
        error_message="$error_message; $1"
    fi
    has_error=true
}

# Function to log cleanup events
log_message() {
    local level="$1"
    local message="$2"
    local LOG_DIR="/tmp/log/apnprofile"
    local LOG_FILE="${LOG_DIR}/apnprofile.log"
    
    # Ensure log directory exists
    mkdir -p "${LOG_DIR}"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} - [${level}] ${message}" >> "$LOG_FILE"
    logger -t apnprofile "${level}: ${message}"
}

log_message "INFO" "Starting APN Profile cleanup process"

# Stop and disable the service
if [ -f "/etc/init.d/apnprofile-service" ]; then
    if /etc/init.d/apnprofile-service stop; then
        log_message "INFO" "APN Profile service stopped"
    else
        append_error "Failed to stop APN Profile service"
        log_message "ERROR" "Failed to stop APN Profile service"
    fi

    if /etc/init.d/apnprofile-service disable; then
        log_message "INFO" "APN Profile service disabled"
    else
        append_error "Failed to disable APN Profile service"
        log_message "ERROR" "Failed to disable APN Profile service"
    fi

    # Remove the init.d script
    if rm -f "/etc/init.d/apnprofile-service"; then
        log_message "INFO" "Removed init.d script"
    else
        append_error "Failed to remove init.d script"
        log_message "ERROR" "Failed to remove init.d script"
    fi
fi

# Remove service script
if [ -f "/www/cgi-bin/services/apnprofile.sh" ]; then
    if rm -f "/www/cgi-bin/services/apnprofile.sh"; then
        log_message "INFO" "Removed service script"
    else
        append_error "Failed to remove service script"
        log_message "ERROR" "Failed to remove service script"
    fi
fi

# Remove symlinks in rc.d if they exist
for link in /etc/rc.d/S??apnprofile-service /etc/rc.d/K??apnprofile-service; do
    if [ -L "$link" ]; then
        if rm -f "$link"; then
            log_message "INFO" "Removed rc.d symlink: $link"
        else
            append_error "Failed to remove rc.d symlink: $link"
            log_message "ERROR" "Failed to remove rc.d symlink: $link"
        fi
    fi
done

# Remove UCI configuration (only removes apn_profile section, leaves other sections intact)
if uci -q get quecmanager.apn_profile >/dev/null; then
    if uci delete quecmanager.apn_profile && uci commit quecmanager; then
        log_message "INFO" "Removed UCI configuration"
    else
        append_error "Failed to remove UCI configuration"
        log_message "ERROR" "Failed to remove UCI configuration"
    fi
fi

# Kill any remaining processes
if pkill -f "/www/cgi-bin/services/apnprofile.sh"; then
    log_message "INFO" "Killed remaining APN Profile processes"
fi

# Clean up temporary files
for file in \
    "/tmp/at_pipe.txt" \
    "/var/run/apnprofile.pid" \
    "/tmp/apn_result.txt" \
    "/tmp/debug.log" \
    "/tmp/inputICCID.txt" \
    "/tmp/outputICCID.txt" \
    "/tmp/inputAPN.txt" \
    "/tmp/outputAPN.txt"
do
    if [ -f "$file" ]; then
        if rm -f "$file"; then
            log_message "INFO" "Removed temporary file: $file"
        else
            append_error "Failed to remove temporary file: $file"
            log_message "ERROR" "Failed to remove temporary file: $file"
        fi
    fi
done

log_message "INFO" "APN Profile cleanup completed"

# Return appropriate JSON response
if [ "$has_error" = true ]; then
    echo "{\"status\": \"error\", \"message\": \"$error_message\"}"
else
    echo "{\"status\": \"success\", \"message\": \"APN Profile service successfully removed\"}"
fi