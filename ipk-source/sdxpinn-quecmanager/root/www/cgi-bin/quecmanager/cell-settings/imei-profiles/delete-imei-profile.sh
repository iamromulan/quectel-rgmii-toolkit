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
    local LOG_DIR="/tmp/log/imeiprofile"
    local LOG_FILE="${LOG_DIR}/imeiprofile.log"
    
    # Ensure log directory exists
    mkdir -p "${LOG_DIR}"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} - [${level}] ${message}" >> "$LOG_FILE"
    logger -t imeiprofile "${level}: ${message}"
}

log_message "INFO" "Starting IMEI Profile cleanup process"

# Stop and disable the service
if [ -f "/etc/init.d/imeiprofile-service" ]; then
    if /etc/init.d/imeiprofile-service stop; then
        log_message "INFO" "IMEI Profile service stopped"
    else
        append_error "Failed to stop IMEI Profile service"
        log_message "ERROR" "Failed to stop IMEI Profile service"
    fi

    if /etc/init.d/imeiprofile-service disable; then
        log_message "INFO" "IMEI Profile service disabled"
    else
        append_error "Failed to disable IMEI Profile service"
        log_message "ERROR" "Failed to disable IMEI Profile service"
    fi

    # Remove the init.d script
    if rm -f "/etc/init.d/imeiprofile-service"; then
        log_message "INFO" "Removed init.d script"
    else
        append_error "Failed to remove init.d script"
        log_message "ERROR" "Failed to remove init.d script"
    fi
fi

# Remove service script
if [ -f "/www/cgi-bin/services/imeiprofile.sh" ]; then
    if rm -f "/www/cgi-bin/services/imeiprofile.sh"; then
        log_message "INFO" "Removed service script"
    else
        append_error "Failed to remove service script"
        log_message "ERROR" "Failed to remove service script"
    fi
fi

# Remove symlinks in rc.d if they exist
for link in /etc/rc.d/S??imeiprofile-service /etc/rc.d/K??imeiprofile-service; do
    if [ -L "$link" ]; then
        if rm -f "$link"; then
            log_message "INFO" "Removed rc.d symlink: $link"
        else
            append_error "Failed to remove rc.d symlink: $link"
            log_message "ERROR" "Failed to remove rc.d symlink: $link"
        fi
    fi
done

# Remove UCI configuration
if uci -q get quecmanager.imei_profile >/dev/null; then
    if uci delete quecmanager.imei_profile && uci commit quecmanager; then
        log_message "INFO" "Removed UCI configuration"
    else
        append_error "Failed to remove UCI configuration"
        log_message "ERROR" "Failed to remove UCI configuration"
    fi
fi

# Kill any remaining processes
if pkill -f "/www/cgi-bin/services/imeiprofile.sh"; then
    log_message "INFO" "Killed remaining IMEI Profile processes"
fi

# Clean up temporary files
for file in \
    "/tmp/at_pipe.txt" \
    "/var/run/imeiprofile.pid" \
    "/tmp/imei_result.txt" \
    "/tmp/debug.log" \
    "/tmp/inputICCID.txt" \
    "/tmp/outputICCID.txt" \
    "/tmp/inputIMEI.txt" \
    "/tmp/outputIMEI.txt"
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

log_message "INFO" "IMEI Profile cleanup completed"

# Return appropriate JSON response
if [ "$has_error" = true ]; then
    echo "{\"status\": \"error\", \"message\": \"$error_message\"}"
else
    echo "{\"status\": \"success\", \"message\": \"IMEI Profile service successfully removed\"}"
fi