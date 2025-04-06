#!/bin/sh

# Cell Lock Remove Script - Called by crontab at end time

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
    logger -t cell_lock_remove -p "daemon.$level" "$message"
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

# Main function to remove cell lock
remove_cell_lock() {
    log_message "Removing cell lock at scheduled end time"
    
    # Mark as inactive in UCI
    uci set "$UCI_CONFIG.cell_lock.active=0"
    uci commit "$UCI_CONFIG"
    
    # Update status
    update_status "inactive" "Cell lock scheduler is inactive - scheduled end time reached" 0 0
    
    # Remove LTE lock
    log_message "Removing LTE lock"
    execute_at_command 'AT+QNWLOCK="common/4g",0' 10
    local lte_status=$?
    
    # Remove NR5G lock
    log_message "Removing NR5G lock"
    execute_at_command 'AT+QNWLOCK="common/5g",0' 10
    local nr5g_status=$?
    
    # Disable persistence
    log_message "Disabling lock persistence"
    execute_at_command 'AT+QNWLOCK="save_ctrl",0,0' 10
    
    # Reset network to apply changes
    log_message "Resetting network connection to apply changes"
    execute_at_command "AT+COPS=2" 5
    sleep 2
    execute_at_command "AT+COPS=0" 5
    
    log_message "Cell lock removed at scheduled end time"
    update_status "inactive" "Cell lock removed at scheduled end time" 0 0
    
    return 0
}

# Execute main function
log_message "====== STARTING SCHEDULED CELL LOCK REMOVAL ======" "notice"
remove_cell_lock
log_message "====== COMPLETED SCHEDULED CELL LOCK REMOVAL ======" "notice"
EOF

    # Copy to quecmanager directory to match crontab
    cp "$SERVICES_DIR/apply_lock.sh" "$QUECMANAGER_DIR/"
    cp "$SERVICES_DIR/remove_lock.sh" "$QUECMANAGER_DIR/"
else
    echo "Scripts found in both locations or only in quecmanager directory"
fi

# Make all scripts executable
chmod +x "$SERVICES_DIR/"*.sh 2>/dev/null
chmod +x "$QUECMANAGER_DIR/"*.sh 2>/dev/null

echo "All scripts are now executable"

# 3. Create test status file
cat > "/tmp/cell_lock_status.json" << EOF
{
    "status": "active",
    "message": "Cell lock scheduler is active",
    "active": 1,
    "locked": 1,
    "timestamp": $(date +%s)
}
EOF
chmod 644 "/tmp/cell_lock_status.json"

echo "Created test status file at /tmp/cell_lock_status.json"

# 4. Check crontab entries and fix if needed
CRONTAB=$(crontab -l)
APPLY_ENTRY=$(echo "$CRONTAB" | grep "apply_lock.sh")
REMOVE_ENTRY=$(echo "$CRONTAB" | grep "remove_lock.sh")

echo "Current crontab entries:"
echo "$CRONTAB" | grep -E "apply_lock.sh|remove_lock.sh"

# Extract times from UCI config
START_TIME=$(uci -q get quecmanager.cell_lock.start_time)
END_TIME=$(uci -q get quecmanager.cell_lock.end_time)

if [ -n "$START_TIME" ] && [ -n "$END_TIME" ]; then
    START_HOUR=$(echo "$START_TIME" | cut -d':' -f1 | sed 's/^0//')
    START_MIN=$(echo "$START_TIME" | cut -d':' -f2 | sed 's/^0//')
    END_HOUR=$(echo "$END_TIME" | cut -d':' -f1 | sed 's/^0//')
    END_MIN=$(echo "$END_TIME" | cut -d':' -f2 | sed 's/^0//')
    
    echo "UCI times: Start=$START_HOUR:$START_MIN, End=$END_HOUR:$END_MIN"
    
    # Verify that crontab entries match UCI config
    NEW_CRONTAB=$(crontab -l | grep -v "apply_lock.sh\|remove_lock.sh")
    NEW_CRONTAB="$NEW_CRONTAB
$START_MIN $START_HOUR * * * $QUECMANAGER_DIR/apply_lock.sh
$END_MIN $END_HOUR * * * $QUECMANAGER_DIR/remove_lock.sh"
    
    echo "Setting crontab with correct paths and times..."
    echo "$NEW_CRONTAB" | crontab -
    
    echo "Updated crontab entries:"
    crontab -l | grep -E "apply_lock.sh|remove_lock.sh"
else
    echo "WARNING: Could not find start/end times in UCI config"
fi

# 5. Test run scripts to verify they work
echo "Testing apply_lock.sh script..."
"$QUECMANAGER_DIR/apply_lock.sh" &
PID=$!
sleep 2
if kill -0 $PID 2>/dev/null; then
    echo "apply_lock.sh is running correctly"
    # Let it complete
    wait $PID
else
    echo "WARNING: apply_lock.sh may have issues"
fi

# 6. Check if log file is being created
if [ -f "/tmp/log/cell_lock/cell_lock.log" ]; then
    echo "Log file exists. Last few entries:"
    tail -n 10 "/tmp/log/cell_lock/cell_lock.log"
else
    echo "WARNING: Log file not found"
fi
