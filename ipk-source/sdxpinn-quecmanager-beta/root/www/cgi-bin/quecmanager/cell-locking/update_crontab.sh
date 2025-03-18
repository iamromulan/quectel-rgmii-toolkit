#!/bin/sh

# Script to update crontab entries for cell lock scheduling

# Configuration
UCI_CONFIG="quecmanager"
LOG_DIR="/tmp/log/cell_lock"
LOG_FILE="$LOG_DIR/cell_lock.log"
SCRIPTS_DIR="/www/cgi-bin/quecmanager/cell-locking"
LOCK_SCRIPT="$SCRIPTS_DIR/apply_lock.sh"
UNLOCK_SCRIPT="$SCRIPTS_DIR/remove_lock.sh"
TEMP_CRONTAB="/tmp/cell_lock_crontab"
ROTATE_SIZE=500  # KB before log rotation

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Enhanced log_message function
log_message() {
    local message="$1"
    local level="${2:-info}"
    local component="update_crontab"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local pid=$$
    
    # Check if log file is too large (>500KB) and rotate if needed
    if [ -f "$LOG_FILE" ] && [ $(du -k "$LOG_FILE" | cut -f1) -gt $ROTATE_SIZE ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi
    
    # Format: [timestamp] [level] [component] [pid] message
    echo "[$timestamp] [$level] [$component] [$pid] $message" >> "$LOG_FILE"
    
    # Also log to system log with appropriate priority
    case "$level" in
        debug)   logger -t "cell_lock_$component" -p daemon.debug "$message" ;;
        info)    logger -t "cell_lock_$component" -p daemon.info "$message" ;;
        notice)  logger -t "cell_lock_$component" -p daemon.notice "$message" ;;
        warn)    logger -t "cell_lock_$component" -p daemon.warning "$message" ;;
        error)   logger -t "cell_lock_$component" -p daemon.err "$message" ;;
        crit)    logger -t "cell_lock_$component" -p daemon.crit "$message" ;;
        *)       logger -t "cell_lock_$component" -p daemon.info "$message" ;;
    esac
}

# Function to update crontab
update_crontab() {
    log_message "Starting crontab update process" "info"
    
    local enabled=$(uci -q get "$UCI_CONFIG.cell_lock.enabled")
    
    # Create a clean temporary crontab file
    crontab -l | grep -v "$SCRIPTS_DIR/" > "$TEMP_CRONTAB" 2>/dev/null
    
    if [ "$enabled" = "1" ]; then
        local start_time=$(uci -q get "$UCI_CONFIG.cell_lock.start_time")
        local end_time=$(uci -q get "$UCI_CONFIG.cell_lock.end_time")
        
        if [ -z "$start_time" ] || [ -z "$end_time" ]; then
            log_message "Missing start or end time in configuration" "error"
            return 1
        fi
        
        log_message "Scheduling cell locks with start=$start_time, end=$end_time" "info"
        
        local start_hour=$(echo "$start_time" | cut -d':' -f1)
        local start_minute=$(echo "$start_time" | cut -d':' -f2)
        local end_hour=$(echo "$end_time" | cut -d':' -f1)
        local end_minute=$(echo "$end_time" | cut -d':' -f2)
        
        # Remove leading zeros
        start_hour=$(echo "$start_hour" | sed 's/^0//')
        start_minute=$(echo "$start_minute" | sed 's/^0//')
        end_hour=$(echo "$end_hour" | sed 's/^0//')
        end_minute=$(echo "$end_minute" | sed 's/^0//')
        
        # Add crontab entries for lock and unlock
        log_message "Adding crontab entry for start time: $start_minute $start_hour * * *" "debug"
        echo "$start_minute $start_hour * * * $LOCK_SCRIPT" >> "$TEMP_CRONTAB"
        
        log_message "Adding crontab entry for end time: $end_minute $end_hour * * *" "debug"
        echo "$end_minute $end_hour * * * $UNLOCK_SCRIPT" >> "$TEMP_CRONTAB"
        
        log_message "Added crontab entries for start time ($start_time) and end time ($end_time)" "info"
    else
        log_message "Cell lock scheduling is disabled, removing crontab entries" "info"
    fi
    
    # Apply the new crontab
    log_message "Applying updated crontab" "debug"
    crontab "$TEMP_CRONTAB"
    local crontab_status=$?
    
    if [ $crontab_status -eq 0 ]; then
        log_message "Crontab updated successfully" "info"
    else
        log_message "Failed to update crontab (status: $crontab_status)" "error"
    fi
    
    # Clean up
    rm -f "$TEMP_CRONTAB"
    
    return $crontab_status
}

# Execute the function
log_message "====== STARTING CRONTAB UPDATE ======" "notice"
update_crontab
log_message "====== COMPLETED CRONTAB UPDATE ======" "notice"