#!/bin/sh

# Log rotation script for cell lock logs

# Configuration
LOG_DIR="/tmp/log/cell_lock"
LOG_FILE="$LOG_DIR/cell_lock.log"
MAX_LOG_SIZE=500  # KB
MAX_LOG_FILES=3   # Number of old log files to keep

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Function to log message
log_message() {
    local message="$1"
    local level="${2:-info}"
    local component="log_rotation"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Use logger directly
    logger -t "cell_lock_$component" -p "daemon.$level" "$message"
}

# Check if log file exists and its size
if [ -f "$LOG_FILE" ]; then
    log_size=$(du -k "$LOG_FILE" | cut -f1)
    
    if [ $log_size -gt $MAX_LOG_SIZE ]; then
        log_message "Log file size ($log_size KB) exceeds maximum ($MAX_LOG_SIZE KB), rotating" "info"
        
        # Rotate old logs
        if [ -f "$LOG_FILE.2" ]; then
            mv "$LOG_FILE.2" "$LOG_FILE.3"
        fi
        
        if [ -f "$LOG_FILE.1" ]; then
            mv "$LOG_FILE.1" "$LOG_FILE.2"
        fi
        
        if [ -f "$LOG_FILE" ]; then
            mv "$LOG_FILE" "$LOG_FILE.1"
        fi
        
        # Create a new empty log file
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
        
        # Log rotation complete
        log_message "Log rotation completed successfully" "info"
        echo "$(date '+%Y-%m-%d %H:%M:%S') [info] [log_rotation] Log file rotated due to size" >> "$LOG_FILE"
    else
        log_message "Log file size ($log_size KB) within limits, no rotation needed" "debug"
    fi
else
    log_message "Log file does not exist, creating it" "info"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [info] [log_rotation] New log file created" >> "$LOG_FILE"
fi