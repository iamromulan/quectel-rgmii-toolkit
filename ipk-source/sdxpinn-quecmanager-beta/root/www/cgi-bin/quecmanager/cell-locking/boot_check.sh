#!/bin/sh

# Boot-time Cell Lock Checker - Called from init.d script at boot

# Configuration
UCI_CONFIG="quecmanager"
LOG_DIR="/tmp/log/cell_lock"
LOG_FILE="$LOG_DIR/cell_lock.log"
STATUS_FILE="/tmp/cell_lock_status.json"
QUEUE_DIR="/tmp/at_queue"
TOKEN_FILE="$QUEUE_DIR/token"
MAX_TOKEN_WAIT=15
TOKEN_PRIORITY=5
ROTATE_SIZE=500 # KB before log rotation

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Enhanced log_message function
log_message() {
    local message="$1"
    local level="${2:-info}"
    local component="boot_check"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local pid=$$

    # Check if log file is too large (>500KB) and rotate if needed
    if [ -f "$LOG_FILE" ] && [ $(du -k "$LOG_FILE" | cut -f1) -gt $ROTATE_SIZE ]; then
        mv "$LOG_FILE" "$LOG_FILE.old"
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi

    # Format: [timestamp] [level] [component] [pid] message
    echo "[$timestamp] [$level] [$component] [$pid] $message" >>"$LOG_FILE"

    # Also log to system log with appropriate priority
    case "$level" in
    debug) logger -t "cell_lock_$component" -p daemon.debug "$message" ;;
    info) logger -t "cell_lock_$component" -p daemon.info "$message" ;;
    notice) logger -t "cell_lock_$component" -p daemon.notice "$message" ;;
    warn) logger -t "cell_lock_$component" -p daemon.warning "$message" ;;
    error) logger -t "cell_lock_$component" -p daemon.err "$message" ;;
    crit) logger -t "cell_lock_$component" -p daemon.crit "$message" ;;
    *) logger -t "cell_lock_$component" -p daemon.info "$message" ;;
    esac
}

# Function to update status
update_status() {
    local status="$1"
    local message="$2"
    local active="${3:-0}"
    local locked="${4:-0}"

    # Create JSON status
    cat >"$STATUS_FILE" <<EOF2
{
    "status": "$status",
    "message": "$message",
    "active": $active,
    "locked": $locked,
    "timestamp": $(date +%s)
}
EOF2
    chmod 644 "$STATUS_FILE"

    log_message "Status updated: $status - $message (active=$active, locked=$locked)" "debug"
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
                log_message "Token held by $current_holder with priority $current_priority, retrying..." "debug"
                sleep 0.5
                attempt=$((attempt + 1))
                continue
            fi
        fi

        # Try to create token file
        echo "{\"id\":\"$requestor_id\",\"priority\":$priority,\"timestamp\":$(date +%s)}" >"$TOKEN_FILE" 2>/dev/null
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

    log_message "AT command executed successfully: $cmd" "debug"
    echo "$output"
    return 0
}

# Function to convert HH:MM to minutes with better error handling
time_to_minutes() {
    local time="$1"

    # Check if time is empty or malformed
    if [ -z "$time" ] || ! echo "$time" | grep -q '^[0-9]\{1,2\}:[0-9]\{2\}$'; then
        log_message "Invalid time format: '$time'" "error"
        echo "0"
        return 1
    fi

    local hours=$(echo "$time" | cut -d':' -f1)
    local minutes=$(echo "$time" | cut -d':' -f2)

    # Remove leading zeros which can cause issues in arithmetic
    hours=$(echo "$hours" | sed 's/^0*//')
    minutes=$(echo "$minutes" | sed 's/^0*//')

    # Default to 0 if empty after removing zeros
    [ -z "$hours" ] && hours=0
    [ -z "$minutes" ] && minutes=0

    echo $((hours * 60 + minutes))
    return 0
}

# Function to check if current time is within scheduled window
is_time_in_range() {
    local current_minutes="$1"
    local start_minutes="$2"
    local end_minutes="$3"

    # Make sure all values are numeric
    if ! [[ "$current_minutes" =~ ^[0-9]+$ ]] ||
        ! [[ "$start_minutes" =~ ^[0-9]+$ ]] ||
        ! [[ "$end_minutes" =~ ^[0-9]+$ ]]; then
        log_message "Non-numeric values in time comparison: current=$current_minutes, start=$start_minutes, end=$end_minutes" "error"
        return 1 # Not in range
    fi

    # Handle case where end time is on the next day
    if [ "$end_minutes" -lt "$start_minutes" ]; then
        if [ "$current_minutes" -ge "$start_minutes" ] || [ "$current_minutes" -lt "$end_minutes" ]; then
            return 0 # In range
        fi
    else
        if [ "$current_minutes" -ge "$start_minutes" ] && [ "$current_minutes" -lt "$end_minutes" ]; then
            return 0 # In range
        fi
    fi

    return 1 # Not in range
}

# Main function to check at boot time
boot_check() {
    log_message "Performing boot-time cell lock check" "info"

    # Check if scheduling is enabled
    local enabled=$(uci -q get "$UCI_CONFIG.cell_lock.enabled")
    if [ "$enabled" != "1" ]; then
        log_message "Cell lock scheduling is disabled" "info"
        update_status "disabled" "Cell lock scheduling is disabled" 0 0
        return 0
    fi

    # Get schedule from UCI
    local start_time=$(uci -q get "$UCI_CONFIG.cell_lock.start_time")
    local end_time=$(uci -q get "$UCI_CONFIG.cell_lock.end_time")

    if [ -z "$start_time" ] || [ -z "$end_time" ]; then
        log_message "Missing start or end time in configuration" "error"
        update_status "error" "Missing schedule configuration" 0 0
        return 1
    fi

    # Get current time
    local current_time=$(date "+%H:%M")

    log_message "Current time: $current_time, Start: $start_time, End: $end_time" "info"

    # Convert times to minutes for comparison
    local current_minutes=$(time_to_minutes "$current_time")
    local start_minutes=$(time_to_minutes "$start_time")
    local end_minutes=$(time_to_minutes "$end_time")

    # Get token for AT commands
    local token_id=$(acquire_token)
    if [ -z "$token_id" ]; then
        log_message "Failed to acquire token for boot check" "error"
        update_status "error" "Failed to acquire token for boot check" 0 0
        return 1
    fi

    # Check if current time is in the scheduled range
    if is_time_in_range "$current_minutes" "$start_minutes" "$end_minutes"; then
        log_message "Current time IS within scheduled window" "info"

        # Get lock parameters from UCI
        local lte_lock_params=$(uci -q get "$UCI_CONFIG.cell_lock.lte_lock")
        local nr5g_lock_params=$(uci -q get "$UCI_CONFIG.cell_lock.nr5g_lock")

        # Apply locks if parameters exist
        local success=0

        if [ -n "$lte_lock_params" ]; then
            log_message "Applying LTE lock at boot: $lte_lock_params" "info"
            local lte_cmd="AT+QNWLOCK=\"common/4g\",$lte_lock_params"
            execute_at_command "$lte_cmd" 10 "$token_id"
            if [ $? -eq 0 ]; then
                log_message "LTE lock applied successfully at boot" "info"
                success=1
            else
                log_message "Failed to apply LTE lock at boot" "error"
            fi
        fi

        if [ -n "$nr5g_lock_params" ]; then
            log_message "Applying NR5G lock at boot: $nr5g_lock_params" "info"
            local nr5g_cmd="AT+QNWLOCK=\"common/5g\",$nr5g_lock_params"
            execute_at_command "$nr5g_cmd" 10 "$token_id"
            if [ $? -eq 0 ]; then
                log_message "NR5G lock applied successfully at boot" "info"
                success=1
            else
                log_message "Failed to apply NR5G lock at boot" "error"
            fi
        fi

        # Apply persist settings
        local lte_persist=$(uci -q get "$UCI_CONFIG.cell_lock.lte_persist")
        local nr5g_persist=$(uci -q get "$UCI_CONFIG.cell_lock.nr5g_persist")

        # Default to 0 if not set
        lte_persist="${lte_persist:-0}"
        nr5g_persist="${nr5g_persist:-0}"

        log_message "Setting persistence at boot: LTE=$lte_persist, NR5G=$nr5g_persist" "info"
        local persist_cmd="AT+QNWLOCK=\"save_ctrl\",$lte_persist,$nr5g_persist"
        execute_at_command "$persist_cmd" 10 "$token_id"

        # Reset network to apply changes
        log_message "Resetting network connection to apply changes" "info"
        execute_at_command "AT+COPS=2" 5 "$token_id"
        sleep 2
        execute_at_command "AT+COPS=0" 5 "$token_id"

        # Mark as active
        uci set "$UCI_CONFIG.cell_lock.active=1"
        uci commit "$UCI_CONFIG"
        update_status "active" "Cell lock scheduler is active - applied at boot" 1 1
    else
        log_message "Current time is NOT within scheduled window" "info"

        # Remove any existing locks
        log_message "Removing LTE lock at boot" "info"
        execute_at_command 'AT+QNWLOCK="common/4g",0' 10 "$token_id"

        log_message "Removing NR5G lock at boot" "info"
        execute_at_command 'AT+QNWLOCK="common/5g",0' 10 "$token_id"

        # Disable persistence
        log_message "Disabling lock persistence at boot" "info"
        execute_at_command 'AT+QNWLOCK="save_ctrl",0,0' 10 "$token_id"

        # Reset network to apply changes
        log_message "Resetting network connection to apply changes" "info"
        execute_at_command "AT+COPS=2" 5 "$token_id"
        sleep 2
        execute_at_command "AT+COPS=0" 5 "$token_id"

        # Mark as inactive
        uci set "$UCI_CONFIG.cell_lock.active=0"
        uci commit "$UCI_CONFIG"
        update_status "inactive" "Cell lock scheduler is inactive - outside scheduled hours" 0 0
    fi

    # Release token
    release_token "$token_id"

    return 0
}

# Execute main function
log_message "====== STARTING BOOT-TIME CELL LOCK CHECK ======" "notice"
boot_check
log_message "====== COMPLETED BOOT-TIME CELL LOCK CHECK ======" "notice"