#!/bin/sh

# Cell Lock Apply Script - Called by crontab at start time

# Configuration
UCI_CONFIG="quecmanager"
LOG_DIR="/tmp/log/cell_lock"
LOG_FILE="$LOG_DIR/cell_lock.log"
STATUS_FILE="/tmp/cell_lock_status.json"
QUEUE_DIR="/tmp/at_queue"
TOKEN_FILE="$QUEUE_DIR/token"
MAX_TOKEN_WAIT=15
TOKEN_PRIORITY=5

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
    logger -t cell_lock_apply -p "daemon.$level" "$message"
}

# Function to update status
update_status() {
    local status="$1"
    local message="$2"
    local active="${3:-0}"
    local locked="${4:-0}"
    
    # Create JSON status
    cat > "$STATUS_FILE" <<EOF2
{
    "status": "$status",
    "message": "$message",
    "active": $active,
    "locked": $locked,
    "timestamp": $(date +%s)
}
EOF2
    chmod 644 "$STATUS_FILE"
    
    log_message "Status updated: $status - $message (active=$active, locked=$locked)"
}

# Function to execute AT command
execute_at_command() {
    local cmd="$1"
    local timeout="${2:-10}"
    
    # Execute the command with proper timeout
    local output
    local status=1
    
    output=$(sms_tool at "$cmd" -t "$timeout" 2>&1)
    status=$?
    
    if [ $status -ne 0 ]; then
        log_message "AT command failed: $cmd (exit code: $status)" "error"
        return 1
    fi
    
    echo "$output"
    return 0
}

# Main function to apply cell lock
apply_cell_lock() {
    log_message "Applying cell lock at scheduled start time"
    
    # Mark as active in UCI
    uci set "$UCI_CONFIG.cell_lock.active=1"
    uci commit "$UCI_CONFIG"
    
    # Update status
    update_status "active" "Cell lock scheduler is active - scheduled start time reached" 1 1
    
    # Get lock parameters from UCI
    local lte_lock_params=$(uci -q get "$UCI_CONFIG.cell_lock.lte_lock")
    local nr5g_lock_params=$(uci -q get "$UCI_CONFIG.cell_lock.nr5g_lock")
    
    log_message "Lock parameters from UCI: LTE=$lte_lock_params, NR5G=$nr5g_lock_params"
    
    # Apply locks if parameters exist
    local success=0
    
    if [ -n "$lte_lock_params" ]; then
        log_message "Applying LTE lock: $lte_lock_params"
        local lte_cmd="AT+QNWLOCK=\"common/4g\",$lte_lock_params"
        execute_at_command "$lte_cmd" 10
        if [ $? -eq 0 ]; then
            log_message "LTE lock applied successfully"
            success=1
        else
            log_message "Failed to apply LTE lock" "error"
        fi
    else
        log_message "No LTE lock parameters found, checking for current lock"
        # If no parameters set, try to lock to current serving cell
        local scan_output=$(execute_at_command "AT+QENG=\"servingcell\"" 5)
        log_message "Current serving cell info: $scan_output"
        # Parse and apply if possible (simplified for this example)
    fi
    
    if [ -n "$nr5g_lock_params" ]; then
        log_message "Applying NR5G lock: $nr5g_lock_params"
        local nr5g_cmd="AT+QNWLOCK=\"common/5g\",$nr5g_lock_params"
        execute_at_command "$nr5g_cmd" 10
        if [ $? -eq 0 ]; then
            log_message "NR5G lock applied successfully"
            success=1
        else
            log_message "Failed to apply NR5G lock" "error"
        fi
    fi
    
    # Apply persist settings
    local lte_persist=$(uci -q get "$UCI_CONFIG.cell_lock.lte_persist")
    local nr5g_persist=$(uci -q get "$UCI_CONFIG.cell_lock.nr5g_persist")
    
    # Default to 0 if not set
    lte_persist="${lte_persist:-0}"
    nr5g_persist="${nr5g_persist:-0}"
    
    local persist_cmd="AT+QNWLOCK=\"save_ctrl\",$lte_persist,$nr5g_persist"
    execute_at_command "$persist_cmd" 10
    
    # Reset network to apply changes
    log_message "Resetting network connection to apply changes"
    execute_at_command "AT+COPS=2" 5
    sleep 2
    execute_at_command "AT+COPS=0" 5
    
    if [ $success -eq 1 ]; then
        log_message "Cell lock applied at scheduled start time"
        update_status "active" "Cell lock applied at scheduled start time" 1 1
    else
        log_message "Failed to apply cell lock" "error"
        update_status "error" "Failed to apply cell lock" 1 0
    fi
    
    return 0
}

# Execute main function
log_message "====== STARTING SCHEDULED CELL LOCK APPLICATION ======" "notice"
apply_cell_lock
log_message "====== COMPLETED SCHEDULED CELL LOCK APPLICATION ======" "notice"