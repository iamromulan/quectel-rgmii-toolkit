#!/bin/sh

# QuecWatch Daemon
# Monitors cellular connectivity and performs recovery actions

# Load UCI configuration functions
. /lib/functions.sh

# Configuration
QUEUE_DIR="/tmp/at_queue"
TOKEN_FILE="$QUEUE_DIR/token"
LOG_DIR="/tmp/log/quecwatch"
LOG_FILE="$LOG_DIR/quecwatch.log"
PID_FILE="/var/run/quecwatch.pid"
STATUS_FILE="/tmp/quecwatch_status.json"
RETRY_COUNT_FILE="/tmp/quecwatch_retry_count"
UCI_CONFIG="quecmanager"
MAX_TOKEN_WAIT=10  # Maximum seconds to wait for token acquisition
TOKEN_PRIORITY=15  # Medium priority (between profiles and metrics)

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
    logger -t quecwatch -p "daemon.$level" "$message"
}

# Function to update status
update_status() {
    local status="$1"
    local message="$2"
    local retry="${3:-$CURRENT_RETRIES}"
    local max="${4:-$MAX_RETRIES}"
    
    # Create JSON status
    cat > "$STATUS_FILE" <<EOF
{
    "status": "$status",
    "message": "$message",
    "retry": $retry,
    "maxRetries": $max,
    "timestamp": $(date +%s)
}
EOF
    chmod 644 "$STATUS_FILE"
    
    log_message "Status updated: $status - $message" "debug"
}

# Function to acquire token for AT commands
acquire_token() {
    local requestor_id="QUECWATCH_$(date +%s)_$$"
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
                # Check if the token is held by a QuecProfile or cell scan
                if echo "$current_holder" | grep -q "CELL_SCAN"; then
                    log_message "Token held by cell scan (priority: $current_priority), waiting..." "debug"
                elif echo "$current_holder" | grep -q "QUECPROFILES"; then
                    log_message "Token held by profile application (priority: $current_priority), waiting..." "debug"
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
    local timeout="${2:-5}"
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

# Function to check internet connectivity
check_internet() {
    local ping_target
    local ping_count=3
    
    # Get ping target from UCI
    config_load "$UCI_CONFIG"
    config_get ping_target quecwatch ping_target
    
    if [ -z "$ping_target" ]; then
        log_message "No ping target configured" "error"
        return 1
    fi
    
    log_message "Checking internet connectivity to $ping_target" "debug"
    
    if ping -c $ping_count "$ping_target" > /dev/null 2>&1; then
        log_message "Internet connectivity check successful" "debug"
        return 0
    else
        log_message "Internet connectivity check failed" "warn"
        return 1
    fi
}

# Function to get current SIM slot
get_current_sim() {
    local token_id=$(acquire_token)
    if [ -z "$token_id" ]; then
        log_message "Failed to acquire token for SIM slot check" "error"
        return 1
    fi
    
    log_message "Checking current SIM slot" "debug"
    
    local result=$(execute_at_command "AT+QUIMSLOT?" 5 "$token_id")
    local status=$?
    
    # Release token
    release_token "$token_id"
    
    if [ $status -eq 0 ] && [ -n "$result" ]; then
        # Extract SIM slot number from response
        local current_sim=$(echo "$result" | grep -o '+QUIMSLOT: [0-9]' | cut -d' ' -f2)
        
        if [ -n "$current_sim" ]; then
            log_message "Current SIM slot: $current_sim" "debug"
            echo "$current_sim"
            return 0
        fi
    fi
    
    log_message "Failed to get current SIM slot" "error"
    return 1
}

# Function to switch SIM card
switch_sim_card() {
    local current_sim
    local target_sim
    local token_id
    
    log_message "Starting SIM card switch operation" "info"
    
    # Get current SIM slot
    current_sim=$(get_current_sim)
    if [ $? -ne 0 ]; then
        log_message "Failed to get current SIM slot, cannot switch" "error"
        return 1
    fi
    
    # Determine target SIM
    if [ "$current_sim" = "1" ]; then
        target_sim=2
    else
        target_sim=1
    fi
    
    log_message "Attempting to switch from SIM $current_sim to SIM $target_sim" "info"
    
    # Get token for AT commands
    token_id=$(acquire_token)
    if [ -z "$token_id" ]; then
        log_message "Failed to acquire token for SIM switch" "error"
        return 1
    fi
    
    # Detach from network
    log_message "Detaching from network" "debug"
    execute_at_command "AT+COPS=2" 10 "$token_id"
    sleep 2
    
    # Switch SIM slot
    log_message "Switching to SIM slot $target_sim" "debug"
    local switch_result=$(execute_at_command "AT+QUIMSLOT=$target_sim" 10 "$token_id")
    local switch_status=$?
    
    # If switch failed, return error
    if [ $switch_status -ne 0 ]; then
        log_message "Failed to switch to SIM $target_sim" "error"
        release_token "$token_id"
        return 1
    fi
    
    sleep 5
    
    # Reattach to network
    log_message "Reattaching to network" "debug"
    execute_at_command "AT+COPS=0" 10 "$token_id"
    
    # Release token
    release_token "$token_id"
    
    # Verify switch
    sleep 10
    local new_sim=$(get_current_sim)
    if [ "$new_sim" = "$target_sim" ]; then
        log_message "Successfully switched to SIM $target_sim" "info"
        return 0
    else
        log_message "Failed to verify SIM switch, current SIM is $new_sim" "error"
        return 1
    fi
}

# Function to perform connection recovery
perform_connection_recovery() {
    local token_id
    
    log_message "Starting connection recovery" "info"
    
    # Get token for AT commands
    token_id=$(acquire_token)
    if [ -z "$token_id" ]; then
        log_message "Failed to acquire token for connection recovery" "error"
        return 1
    fi

    # First check if CFUN is 1, if not set it to 1
    local cfun_status=$(execute_at_command "AT+CFUN?" 5 "$token_id")
    if [ $? -ne 0 ]; then
        log_message "Failed to get CFUN status" "error"
        release_token "$token_id"
        return 1
    fi

    if echo "$cfun_status" | grep -q '+CFUN: 1'; then
        log_message "CFUN is already 1, no action needed" "debug"
    else
        log_message "Setting CFUN to 1"
        execute_at_command "AT+CFUN=1" 10 "$token_id"
        sleep 2
        
        # Recheck CFUN status
        cfun_status=$(execute_at_command "AT+CFUN?" 5 "$token_id")
        if [ $? -ne 0 ] || ! echo "$cfun_status" | grep -q '+CFUN: 1'; then
            log_message "Failed to set CFUN to 1" "error"
            release_token "$token_id"
            return 1
        fi

        log_message "CFUN set to 1 successfully" "debug"
        sleep 2
    fi
    
    # Detach from network
    log_message "Detaching from network" "debug"
    execute_at_command "AT+COPS=2" 10 "$token_id"
    sleep 2
    
    # Reattach to network
    log_message "Reattaching to network" "debug"
    execute_at_command "AT+COPS=0" 15 "$token_id"
    
    # Release token
    release_token "$token_id"
    
    # Verify recovery
    sleep 10
    if check_internet; then
        log_message "Connection recovery successful" "info"
        return 0
    else
        log_message "Connection recovery failed" "error"
        return 1
    fi
}

# Load configuration
load_config() {
    # Initialize variables
    PING_TARGET=""
    PING_INTERVAL=60
    PING_FAILURES=3
    MAX_RETRIES=5
    CURRENT_RETRIES=0
    CONNECTION_REFRESH=0
    REFRESH_COUNT=3
    AUTO_SIM_FAILOVER=0
    SIM_FAILOVER_SCHEDULE=0
    
    # Load from UCI
    config_load "$UCI_CONFIG"
    
    # Get settings with defaults
    config_get PING_TARGET quecwatch ping_target
    config_get PING_INTERVAL quecwatch ping_interval 60
    config_get PING_FAILURES quecwatch ping_failures 3
    config_get MAX_RETRIES quecwatch max_retries 5
    config_get CURRENT_RETRIES quecwatch current_retries 0
    config_get_bool CONNECTION_REFRESH quecwatch connection_refresh 0
    config_get REFRESH_COUNT quecwatch refresh_count 3
    config_get_bool AUTO_SIM_FAILOVER quecwatch auto_sim_failover 0
    config_get SIM_FAILOVER_SCHEDULE quecwatch sim_failover_schedule 0
    
    # Validate required settings
    if [ -z "$PING_TARGET" ]; then
        log_message "No ping target configured, using default (8.8.8.8)" "warn"
        PING_TARGET="8.8.8.8"
        uci set "$UCI_CONFIG.quecwatch.ping_target=$PING_TARGET"
        uci commit "$UCI_CONFIG"
    fi
    
    # Load persisted retry count if available
    if [ -f "$RETRY_COUNT_FILE" ]; then
        CURRENT_RETRIES=$(cat "$RETRY_COUNT_FILE")
    fi
    
    log_message "Configuration loaded: ping_target=$PING_TARGET, interval=$PING_INTERVAL, failures=$PING_FAILURES, max_retries=$MAX_RETRIES, current_retries=$CURRENT_RETRIES" "info"
}

# Save retry count to both UCI and file
save_retry_count() {
    local count=$1
    
    # Update UCI
    uci set "$UCI_CONFIG.quecwatch.current_retries=$count"
    uci commit "$UCI_CONFIG"
    
    # Update file for crash recovery
    echo "$count" > "$RETRY_COUNT_FILE"
    chmod 644 "$RETRY_COUNT_FILE"
    
    log_message "Updated retry count to $count" "debug"
}

# Main monitoring function
main() {
    log_message "QuecWatch daemon starting (PID: $$)" "info"
    
    # Load configuration
    load_config
    
    # Initial status update
    update_status "active" "Monitoring started"
    
    # Track consecutive failures
    local failure_count=0
    
    # For scheduled SIM failover
    local sim_failover_interval=0
    local initial_sim=""
    
    # If auto SIM failover is enabled, store initial SIM slot
    if [ "$AUTO_SIM_FAILOVER" -eq 1 ]; then
        initial_sim=$(get_current_sim)
        if [ -n "$initial_sim" ]; then
            log_message "Auto SIM failover enabled, initial SIM slot: $initial_sim" "info"
        fi
    fi
    
    # Main monitoring loop
    while true; do
        log_message "Starting monitoring cycle" "debug"
        
        # Check internet connectivity
        if ! check_internet; then
            failure_count=$((failure_count + 1))
            log_message "Connectivity check failed ($failure_count/$PING_FAILURES)" "warn"
            
            # Update status
            update_status "warning" "Connection check failed: $failure_count/$PING_FAILURES failures"
            
            # Check if failure threshold is reached
            if [ $failure_count -ge $PING_FAILURES ]; then
                # Reset failure counter
                failure_count=0
                
                # Increment retry counter
                CURRENT_RETRIES=$((CURRENT_RETRIES + 1))
                save_retry_count $CURRENT_RETRIES
                
                log_message "Failure threshold reached. Current retry: $CURRENT_RETRIES/$MAX_RETRIES" "warn"
                update_status "error" "Connection lost, attempt $CURRENT_RETRIES/$MAX_RETRIES to recover"
                
                # Check if max retries reached
                if [ $CURRENT_RETRIES -ge $MAX_RETRIES ]; then
                    log_message "Maximum retries reached" "error"
                    
                    # Try SIM failover if enabled
                    if [ "$AUTO_SIM_FAILOVER" -eq 1 ]; then
                        log_message "Attempting SIM failover" "info"
                        update_status "failover" "Maximum retries reached, attempting SIM failover"
                        
                        if switch_sim_card && check_internet; then
                            log_message "SIM failover successful, connection restored" "info"
                            update_status "recovered" "Connection restored via SIM failover"
                            
                            # Reset retry counter
                            CURRENT_RETRIES=0
                            save_retry_count $CURRENT_RETRIES
                        else
                            log_message "SIM failover failed, system will reboot" "error"
                            update_status "rebooting" "SIM failover failed, system will reboot"
                            
                            # Wait briefly and reboot
                            sleep 5
                            reboot
                        fi
                    else
                        log_message "Auto SIM failover disabled, system will reboot" "error"
                        update_status "rebooting" "Maximum retries reached, system will reboot"
                        
                        # Wait briefly and reboot
                        sleep 5
                        reboot
                    fi
                else
                    # Try connection recovery
                    log_message "Attempting connection recovery" "info"
                    update_status "recovering" "Attempting to restore connection"
                    
                    if perform_connection_recovery; then
                        log_message "Connection recovery successful" "info"
                        update_status "recovered" "Connection restored"
                        
                        # Reset retry counter
                        CURRENT_RETRIES=0
                        save_retry_count $CURRENT_RETRIES
                    fi
                fi
            fi
        else
            # Connection is good
            if [ $failure_count -gt 0 ] || [ $CURRENT_RETRIES -gt 0 ]; then
                log_message "Connection restored" "info"
                update_status "stable" "Connection restored"
                
                # Reset counters
                failure_count=0
                CURRENT_RETRIES=0
                save_retry_count $CURRENT_RETRIES
            fi
            
            # Scheduled SIM failover check
            if [ "$AUTO_SIM_FAILOVER" -eq 1 ] && [ "$SIM_FAILOVER_SCHEDULE" -gt 0 ] && [ -n "$initial_sim" ]; then
                # Get current SIM to check if we're on the backup
                local current_sim=$(get_current_sim)
                
                # If we're on backup SIM, check if it's time to try primary again
                if [ -n "$current_sim" ] && [ "$current_sim" != "$initial_sim" ]; then
                    sim_failover_interval=$((sim_failover_interval + 1))
                    
                    # Check if we've reached the scheduled time
                    if [ $((sim_failover_interval * PING_INTERVAL)) -ge $((SIM_FAILOVER_SCHEDULE * 60)) ]; then
                        log_message "Scheduled check: attempting to switch back to primary SIM $initial_sim" "info"
                        update_status "switchback" "Attempting to switch back to primary SIM"
                        
                        # Try switching back
                        if switch_sim_card && check_internet; then
                            log_message "Successfully switched back to primary SIM" "info"
                            update_status "stable" "Successfully switched back to primary SIM"
                        else
                            log_message "Failed to switch back to primary SIM, staying on backup" "warn"
                            update_status "stable" "Staying on backup SIM - primary SIM check failed"
                            
                            # Switch back to backup SIM
                            current_sim=$(get_current_sim)
                            if [ -n "$current_sim" ] && [ "$current_sim" = "$initial_sim" ]; then
                                switch_sim_card
                            fi
                        fi
                        
                        # Reset failover interval
                        sim_failover_interval=0
                    fi
                fi
            fi
        fi
        
        # Sleep for the configured interval
        sleep $PING_INTERVAL
    done
}

# Set up trap for clean shutdown
trap 'log_message "Received signal, exiting" "info"; update_status "stopped" "Daemon stopped"; rm -f "$PID_FILE"; exit 0' INT TERM

# Start the main function
main