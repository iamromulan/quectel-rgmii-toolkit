#!/bin/sh

# Cell Lock Scheduler Daemon
# Monitors schedule and applies/restores cell locks as needed

# Load UCI configuration functions
. /lib/functions.sh

# Configuration
QUEUE_DIR="/tmp/at_queue"
TOKEN_FILE="$QUEUE_DIR/token"
LOG_DIR="/tmp/log/cell_lock"
LOG_FILE="$LOG_DIR/cell_lock.log"
PID_FILE="/var/run/cell_lock_scheduler.pid"
STATUS_FILE="/tmp/cell_lock_status.json"
UCI_CONFIG="quecmanager"
CHECK_INTERVAL=60  # Check schedule every minute
MAX_TOKEN_WAIT=15  # Maximum seconds to wait for token acquisition
TOKEN_PRIORITY=5   # Higher priority than QuecWatch (which is 15)

# Ensure directories exist
mkdir -p "$LOG_DIR" "$QUEUE_DIR"

# Store PID
echo "$$" > "$PID_FILE"
chmod 644 "$PID_FILE"

# Function to log messages
log_message() {
    local level="${2:-info}"
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Log to system log
    logger -t cell_lock -p "daemon.$level" "$message"
}

# Function to update status
update_status() {
    local status="$1"
    local message="$2"
    local active="${3:-0}"
    local locked="${4:-0}"
    
    # Create JSON status
    cat > "$STATUS_FILE" <<EOF
{
    "status": "$status",
    "message": "$message",
    "active": $active,
    "locked": $locked,
    "timestamp": $(date +%s)
}
EOF
    chmod 644 "$STATUS_FILE"
    
    log_message "Status updated: $status - $message" "debug"
}

# Function to acquire token for AT commands
acquire_token() {
    local requestor_id="CELLLOCK_$(date +%s)_$$"
    local priority="$TOKEN_PRIORITY"
    local max_attempts=$MAX_TOKEN_WAIT
    local attempt=0
    
    log_message "Attempting to acquire token with priority $priority" "debug"
    
    while [ $attempt -lt $max_attempts ]; do
        # Check if token file exists
        if [ -f "$TOKEN_FILE" ]; then
            local current_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id' 2>/dev/null)
            local current_priority=$(cat "$TOKEN_FILE" | jsonfilter -e '@.priority' 2>/dev/null)
            local timestamp=$(cat "$TOKEN_FILE" | jsonfilter -e '@.timestamp' 2>/dev/null)
            local current_time=$(date +%s)
            
            # Check for expired token (> 30 seconds old)
            if [ $((current_time - timestamp)) -gt 30 ] || [ -z "$current_holder" ]; then
                # Remove expired token
                log_message "Found expired token from $current_holder, removing" "debug"
                rm -f "$TOKEN_FILE" 2>/dev/null
            elif [ $priority -lt $current_priority ]; then
                # Preempt lower priority token
                log_message "Preempting token from $current_holder (priority: $current_priority)" "debug"
                rm -f "$TOKEN_FILE" 2>/dev/null
            else
                # Check if the token is held by a cell scan
                if echo "$current_holder" | grep -q "CELL_SCAN"; then
                    log_message "Token held by cell scan (priority: $current_priority), waiting..." "debug"
                else
                    log_message "Token held by $current_holder with priority $current_priority, retrying..." "debug"
                fi
                
                sleep 0.5
                attempt=$((attempt + 1))
                continue
            fi
        fi
        
        # Try to create token file
        echo "{\"id\":\"$requestor_id\",\"priority\":$priority,\"timestamp\":$(date +%s)}" > "$TOKEN_FILE" 2>/dev/null
        chmod 644 "$TOKEN_FILE" 2>/dev/null
        
        # Verify we got the token
        local holder=$(cat "$TOKEN_FILE" 2>/dev/null | jsonfilter -e '@.id' 2>/dev/null)
        if [ "$holder" = "$requestor_id" ]; then
            log_message "Successfully acquired token with ID $requestor_id" "debug"
            echo "$requestor_id"
            return 0
        fi
        
        sleep 0.5
        attempt=$((attempt + 1))
    done
    
    log_message "Failed to acquire token after $max_attempts attempts" "error"
    return 1
}

# Function to release token
release_token() {
    local requestor_id="$1"
    
    if [ -f "$TOKEN_FILE" ]; then
        local current_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id' 2>/dev/null)
        if [ "$current_holder" = "$requestor_id" ]; then
            rm -f "$TOKEN_FILE" 2>/dev/null
            log_message "Released token $requestor_id" "debug"
            return 0
        fi
        log_message "Token held by $current_holder, not by us ($requestor_id)" "warn"
    else
        log_message "Token file doesn't exist, nothing to release" "debug"
    fi
    return 1
}

# Function to execute AT command with token
execute_at_command() {
    local cmd="$1"
    local timeout="${2:-10}"
    local token_id="$3"
    
    if [ -z "$token_id" ]; then
        log_message "No valid token provided for command: $cmd" "error"
        return 1
    fi
    
    log_message "Executing AT command: $cmd (timeout: ${timeout}s)" "debug"
    
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

# Function to check current lock status
check_lock_status() {
    local token_id="$1"
    
    log_message "Checking current cell lock status" "debug"
    
    # Check LTE lock status
    local lte_status=$(execute_at_command 'AT+QNWLOCK="common/4g"' 5 "$token_id")
    local nr5g_status=$(execute_at_command 'AT+QNWLOCK="common/5g"' 5 "$token_id")
    
    # Check if any lock is active
    if echo "$lte_status" | grep -q '"common/4g",0'; then
        if echo "$nr5g_status" | grep -q '"common/5g",0'; then
            log_message "No active cell locks detected" "debug"
            return 1
        fi
    fi
    
    log_message "Active cell locks detected" "debug"
    return 0
}

# Function to get current lock parameters and save to UCI
store_current_lock_params() {
    local token_id="$1"
    
    log_message "Storing current lock parameters" "debug"
    
    # Get LTE lock status
    local lte_status=$(execute_at_command 'AT+QNWLOCK="common/4g"' 5 "$token_id")
    if [ $? -eq 0 ]; then
        # Extract parameters
        local lte_params=$(echo "$lte_status" | grep -o '"common/4g",[^[:space:]]*' | cut -d',' -f2-)
        
        # Save to UCI
        uci set "$UCI_CONFIG.cell_lock.lte_params='$lte_params'"
        log_message "Stored LTE parameters: $lte_params" "debug"
    fi
    
    # Get NR5G lock status
    local nr5g_status=$(execute_at_command 'AT+QNWLOCK="common/5g"' 5 "$token_id")
    if [ $? -eq 0 ]; then
        # Extract parameters
        local nr5g_params=$(echo "$nr5g_status" | grep -o '"common/5g",[^[:space:]]*' | cut -d',' -f2-)
        
        # Save to UCI
        uci set "$UCI_CONFIG.cell_lock.nr5g_params='$nr5g_params'"
        log_message "Stored NR5G parameters: $nr5g_params" "debug"
    fi
    
    # Get persist settings
    local persist_status=$(execute_at_command 'AT+QNWLOCK="save_ctrl"' 5 "$token_id")
    if [ $? -eq 0 ]; then
        # Extract parameters (LTE persist is at index 1, NR5G persist is at index 2)
        local persist_params=$(echo "$persist_status" | grep -o '"save_ctrl",[^[:space:]]*' | cut -d',' -f2-)
        local lte_persist=$(echo "$persist_params" | cut -d',' -f1)
        local nr5g_persist=$(echo "$persist_params" | cut -d',' -f2)
        
        # Save to UCI
        uci set "$UCI_CONFIG.cell_lock.lte_persist='$lte_persist'"
        uci set "$UCI_CONFIG.cell_lock.nr5g_persist='$nr5g_persist'"
        log_message "Stored persist settings: LTE=$lte_persist, NR5G=$nr5g_persist" "debug"
    fi
    
    # Commit changes
    uci commit "$UCI_CONFIG"
    return 0
}

# Function to check if time is in range
is_time_in_range() {
    local current_time_minutes=$1
    local start_time_minutes=$2
    local end_time_minutes=$3
    
    # Handle case where end time is on the next day
    if [ $end_time_minutes -lt $start_time_minutes ]; then
        if [ $current_time_minutes -ge $start_time_minutes ] || [ $current_time_minutes -lt $end_time_minutes ]; then
            return 0
        fi
    else
        if [ $current_time_minutes -ge $start_time_minutes ] && [ $current_time_minutes -lt $end_time_minutes ]; then
            return 0
        fi
    fi
    
    return 1
}

# Function to convert HH:MM to minutes
time_to_minutes() {
    local time="$1"
    local hours=$(echo "$time" | cut -d':' -f1)
    local minutes=$(echo "$time" | cut -d':' -f2)
    
    echo $((hours * 60 + minutes))
}

# Function to check schedule and manage cell locks
check_schedule() {
    local enabled
    local start_time
    local end_time
    local current_active
    
    # Get current scheduler state from UCI
    config_load "$UCI_CONFIG"
    config_get_bool enabled cell_lock enabled 0
    
    if [ "$enabled" -ne 1 ]; then
        log_message "Cell lock scheduler is disabled" "debug"
        update_status "disabled" "Scheduler is disabled" 0 0
        return 0
    fi
    
    # Get schedule from UCI
    config_get start_time cell_lock start_time
    config_get end_time cell_lock end_time
    config_get current_active cell_lock active 0
    
    if [ -z "$start_time" ] || [ -z "$end_time" ]; then
        log_message "Missing start or end time in configuration" "error"
        update_status "error" "Missing schedule configuration" 0 0
        return 1
    }
    
    # Get current time
    local current_time=$(date "+%H:%M")
    
    # Convert times to minutes for comparison
    local current_minutes=$(time_to_minutes "$current_time")
    local start_minutes=$(time_to_minutes "$start_time")
    local end_minutes=$(time_to_minutes "$end_time")
    
    # Get token for AT commands
    local token_id=$(acquire_token)
    if [ -z "$token_id" ]; then
        log_message "Failed to acquire token for checking schedule" "error"
        update_status "error" "Failed to acquire token for checking schedule" 0 0
        return 1
    }
    
    # Check if any cell lock is currently active
    local lock_active=0
    check_lock_status "$token_id" && lock_active=1
    
    # Check if current time is in the scheduled range
    if is_time_in_range "$current_minutes" "$start_minutes" "$end_minutes"; then
        # We're in the active window
        if [ "$current_active" -ne 1 ]; then
            # We just entered the window, need to save current state
            log_message "Entering scheduled window" "info"
            
            # Store current lock parameters if a lock is active
            if [ $lock_active -eq 1 ]; then
                log_message "Storing current cell lock parameters" "info"
                store_current_lock_params "$token_id"
            else
                log_message "No active cell locks to store" "info"
                update_status "inactive" "Schedule active but no cell locks configured" 1 0
                release_token "$token_id"
                return 0
            }
            
            # Update status
            uci set "$UCI_CONFIG.cell_lock.active=1"
            uci commit "$UCI_CONFIG"
            update_status "active" "Cell lock scheduler is active" 1 $lock_active
        else
            update_status "active" "Cell lock scheduler is active" 1 $lock_active
        }
    else
        # We're outside the active window
        if [ "$current_active" -eq 1 ]; then
            # We just exited the window
            log_message "Exiting scheduled window" "info"
            
            # Update status
            uci set "$UCI_CONFIG.cell_lock.active=0"
            uci commit "$UCI_CONFIG"
            update_status "inactive" "Outside scheduled hours" 0 $lock_active
        } else {
            update_status "inactive" "Outside scheduled hours" 0 $lock_active
        }
    fi
    
    # Release token
    release_token "$token_id"
    
    return 0
}

# Main function
main() {
    log_message "Cell lock scheduler daemon starting (PID: $$)" "info"
    
    # Ensure UCI section exists
    if ! uci -q get "$UCI_CONFIG.cell_lock" >/dev/null; then
        uci set "$UCI_CONFIG.cell_lock=scheduler"
        uci set "$UCI_CONFIG.cell_lock.enabled=0"
        uci set "$UCI_CONFIG.cell_lock.active=0"
        uci commit "$UCI_CONFIG"
        log_message "Created cell lock UCI configuration" "info"
    fi
    
    # Initialize status
    update_status "starting" "Cell lock scheduler daemon starting" 0 0
    
    # Get token and check if any locks are active
    local token_id=$(acquire_token)
    if [ -n "$token_id" ]; then
        local lock_active=0
        check_lock_status "$token_id" && lock_active=1
        release_token "$token_id"
        
        # Update status based on current state
        local enabled=$(uci -q get "$UCI_CONFIG.cell_lock.enabled")
        if [ "$enabled" = "1" ]; then
            # Get schedule from UCI
            local start_time=$(uci -q get "$UCI_CONFIG.cell_lock.start_time")
            local end_time=$(uci -q get "$UCI_CONFIG.cell_lock.end_time")
            
            if [ -n "$start_time" ] && [ -n "$end_time" ]; then
                # Check if we're currently in the schedule window
                local current_time=$(date "+%H:%M")
                local current_minutes=$(time_to_minutes "$current_time")
                local start_minutes=$(time_to_minutes "$start_time")
                local end_minutes=$(time_to_minutes "$end_time")
                
                if is_time_in_range "$current_minutes" "$start_minutes" "$end_minutes"; then
                    update_status "active" "Cell lock scheduler is active" 1 $lock_active
                    uci set "$UCI_CONFIG.cell_lock.active=1"
                    uci commit "$UCI_CONFIG"
                } else {
                    update_status "inactive" "Cell lock scheduler is enabled but outside scheduled hours" 0 $lock_active
                    uci set "$UCI_CONFIG.cell_lock.active=0"
                    uci commit "$UCI_CONFIG"
                }
            } else {
                update_status "error" "Missing schedule configuration" 0 $lock_active
            }
        } else {
            update_status "disabled" "Cell lock scheduler is disabled" 0 $lock_active
        }
    } else {
        log_message "Failed to acquire token for initial status check" "error"
    }
    
    # Main monitoring loop
    while true; do
        check_schedule
        sleep $CHECK_INTERVAL
    done
}

# Set up trap for clean shutdown
trap 'log_message "Received signal, exiting" "info"; update_status "stopped" "Daemon stopped" 0 0; rm -f "$PID_FILE"; exit 0' INT TERM

# Start the main function
main