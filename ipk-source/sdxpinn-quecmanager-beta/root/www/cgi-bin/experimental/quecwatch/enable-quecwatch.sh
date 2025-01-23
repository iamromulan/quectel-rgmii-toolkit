#!/bin/sh

# Read POST data
read -r QUERY_STRING

# Function to urldecode
urldecode() {
    echo -e "$(echo "$1" | sed 's/+/ /g;s/%\([0-9A-F][0-9A-F]\)/\\x\1/g')"
}

# Configuration directory
CONFIG_DIR="/etc/quecmanager/quecwatch"
QUECWATCH_CONFIG="${CONFIG_DIR}/quecwatch.conf"
QUECWATCH_SCRIPT="${CONFIG_DIR}/quecwatch.sh"
RCLOCAL="/etc/rc.local"
LOG_DIR="/tmp/log/quecwatch"
DEBUG_LOG_FILE="${LOG_DIR}/debug.log"

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Extract values from POST data
action=$(echo "$QUERY_STRING" | grep -o 'action=[^&]*' | cut -d= -f2)
ping_target=$(echo "$QUERY_STRING" | grep -o 'ping_target=[^&]*' | cut -d= -f2)
ping_interval=$(echo "$QUERY_STRING" | grep -o 'ping_interval=[^&]*' | cut -d= -f2)
ping_failures=$(echo "$QUERY_STRING" | grep -o 'ping_failures=[^&]*' | cut -d= -f2)
max_retries=$(echo "$QUERY_STRING" | grep -o 'max_retries=[^&]*' | cut -d= -f2)
connection_refresh=$(echo "$QUERY_STRING" | grep -o 'connection_refresh=[^&]*' | cut -d= -f2)
auto_sim_failover=$(echo "$QUERY_STRING" | grep -o 'auto_sim_failover=[^&]*' | cut -d= -f2)
sim_failover_schedule=$(echo "$QUERY_STRING" | grep -o 'sim_failover_schedule=[^&]*' | cut -d= -f2)

# URL decode the values
action=$(urldecode "$action")
ping_target=$(urldecode "$ping_target")
ping_interval=$(urldecode "$ping_interval")
ping_failures=$(urldecode "$ping_failures")
max_retries=$(urldecode "$max_retries")
connection_refresh=$(urldecode "$connection_refresh")
auto_sim_failover=$(urldecode "$auto_sim_failover")
sim_failover_schedule=$(urldecode "$sim_failover_schedule")

# Default response headers
echo "Content-type: application/json"
echo ""

# Validate inputs
if [ -z "$ping_target" ]; then
    echo '{"status": "error", "message": "Ping target is required"}'
    exit 1
fi

# Initialize configuration function
initialize_config() {
    # Create config directory if not exists
    mkdir -p "${CONFIG_DIR}"

    # Write configuration with defaults and user-provided values
    cat >"${QUECWATCH_CONFIG}" <<EOL
# QuecWatch Configuration File
# Ping Target (IP or domain to ping)
PING_TARGET=${ping_target}
# Interval between ping checks (in seconds)
PING_INTERVAL=${ping_interval:-30}
# Number of consecutive ping failures before taking action
PING_FAILURES=${ping_failures:-3}
# Maximum number of retry attempts
MAX_RETRIES=${max_retries:-5}
# Current retry count (should start at 0)
CURRENT_RETRIES=0
# Enable/Disable Connection Refresh
CONNECTION_REFRESH=${connection_refresh:-false}
# Number of connection refresh attempts
REFRESH_COUNT=${connection_refresh:+3}
# Enable/Disable Auto SIM Failover
AUTO_SIM_FAILOVER=${auto_sim_failover:-false}
# Schedule for checking initial SIM (in minutes)
# 0 means no scheduled check
SIM_FAILOVER_SCHEDULE=${sim_failover_schedule:-0}
# Indicate that QuecWatch is enabled
ENABLED=true
EOL

    chmod 644 "${QUECWATCH_CONFIG}"
}

# Generate monitoring script function
generate_monitoring_script() {
    cat >"${QUECWATCH_SCRIPT}" <<'EOL'
#!/bin/sh

# Load configuration
. /etc/quecmanager/quecwatch/quecwatch.conf

# Define file paths
QUEUE_FILE="/tmp/at_pipe.txt"
LOG_FILE="/tmp/log/quecwatch/quecwatch.log"
[ ! -f "${QUEUE_FILE}" ] && touch "${QUEUE_FILE}"

# Function to persist retry count to a more permanent location
persist_retry_count() {
    local count=$1
    echo "$count" > /etc/quecmanager/quecwatch/retry_count
}

# Function to load persisted retry count
load_retry_count() {
    if [ -f /etc/quecmanager/quecwatch/retry_count ]; then
        cat /etc/quecmanager/quecwatch/retry_count
    else
        echo "0"
    fi
}

# Enhanced logging function with debug level
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} - [${level}] ${message}" >> "$LOG_FILE"
    logger -t quecwatch "${level}: ${message}"
}

# Check for stale entries and clean them
check_and_clean_stale() {
    local command_type="$1"
    local wait_count=0
    
    while [ $wait_count -lt 6 ]; do
        if grep -q "\"command\":\"${command_type}\"" "$QUEUE_FILE"; then
            log_message "DEBUG" "Waiting for ${command_type} to clear (attempt ${wait_count})"
            sleep 1
            wait_count=$((wait_count + 1))
        else
            return 0
        fi
    done
    
    log_message "WARN" "Removing stale ${command_type} entry after ${wait_count}s"
    sed -i "/\"command\":\"${command_type}\"/d" "$QUEUE_FILE"
    return 0
}

# Handle lock with debug logging
handle_lock() {
    log_message "DEBUG" "Checking queue file status before lock"
    if [ -f "$QUEUE_FILE" ]; then
        log_message "DEBUG" "Current queue content: $(cat $QUEUE_FILE)"
    else
        log_message "DEBUG" "Queue file does not exist, creating it"
        touch "$QUEUE_FILE"
    fi
    
    check_and_clean_stale "FETCH_LOCK"
    
    log_message "DEBUG" "Adding AT_COMMAND entry to queue"
    printf '{"command":"AT_COMMAND","pid":"%s","timestamp":"%s"}\n' \
        "$$" \
        "$(date '+%H:%M:%S')" >> "$QUEUE_FILE"
    
    check_and_clean_stale "AT_COMMAND"
}

# Execute AT command with enhanced error handling
execute_at_command() {
    local command="$1"
    local result=""
    local retry_count=0
    local max_retries=3
    
    log_message "DEBUG" "Executing AT command: ${command}"
    
    while [ $retry_count -lt $max_retries ]; do
        handle_lock
        
        result=$(sms_tool at "$command" -t 4 2>&1)
        local status=$?
        
        log_message "DEBUG" "Removing our entry from queue"
        sed -i "/\"pid\":\"$$\"/d" "$QUEUE_FILE"
        
        if [ $status -eq 0 ] && [ -n "$result" ]; then
            log_message "DEBUG" "Command successful. Output: $result"
            echo "$result"
            return 0
        fi
        
        log_message "WARN" "Command failed (attempt $((retry_count + 1))): $result"
        retry_count=$((retry_count + 1))
        [ $retry_count -lt $max_retries ] && sleep 2
    done
    
    log_message "ERROR" "Command failed after $max_retries attempts: $command"
    return 1
}

# Function to update retry count in config and persistent storage
update_retry_count() {
    local new_retry_count=$1
    # Update the persistent count file
    persist_retry_count "$new_retry_count"
    # Update the config file
    sed -i "s/CURRENT_RETRIES=[0-9]*/CURRENT_RETRIES=${new_retry_count}/" /etc/quecmanager/quecwatch/quecwatch.conf
    # Reload config to ensure latest values
    . /etc/quecmanager/quecwatch/quecwatch.conf
}

# Function to get current SIM slot with enhanced error handling
get_current_sim() {
    local output
    local retry_count=0
    local max_retries=3
    
    while [ $retry_count -lt $max_retries ]; do
        output=$(execute_at_command "AT+QUIMSLOT?")
        if [ $? -eq 0 ] && echo "$output" | grep -q "+QUIMSLOT:"; then
            echo "$output" | grep "+QUIMSLOT:" | awk '{print $2}'
            return 0
        fi
        retry_count=$((retry_count + 1))
        [ $retry_count -lt $max_retries ] && sleep 2
    done
    
    log_message "ERROR" "Failed to get current SIM slot after $max_retries attempts"
    return 1
}

# Function to switch SIM card with enhanced error handling
switch_sim_card() {
    log_message "INFO" "Attempting to switch SIM card"
    
    # Get current SIM slot
    current_sim_slot=$(get_current_sim)
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to get current SIM slot"
        return 1
    fi
    
    # Toggle between SIM slots
    new_sim_slot=$((current_sim_slot % 2 + 1))
    
    log_message "INFO" "Switching from SIM slot ${current_sim_slot} to SIM slot ${new_sim_slot}"
    if ! execute_at_command "AT+QUIMSLOT=${new_sim_slot}"; then
        log_message "ERROR" "Failed to switch to SIM slot ${new_sim_slot}"
        return 1
    fi
    
    sleep 10  # Allow time for SIM switch and network registration
    return 0
}

# Function to check internet connectivity
check_internet() {
    ping -c 3 ${PING_TARGET} > /dev/null 2>&1
    return $?
}

# Function to perform connection recovery
perform_connection_recovery() {
    local recovery_attempted=0
    local recovery_successful=0

    if [ "${CONNECTION_REFRESH}" = "true" ] && [ "${retry_trigger}" -eq 1 ] && [ "${REFRESH_COUNT}" -gt 0 ]; then
        log_message "INFO" "Attempting connection refresh"
        
        if ! execute_at_command "AT+COPS=2"; then
            log_message "ERROR" "Failed to detach from network"
            return 1
        fi
        
        sleep 2
        
        if ! execute_at_command "AT+COPS=0"; then
            log_message "ERROR" "Failed to reattach to network"
            return 1
        fi
        
        sleep 5
        
        if check_internet; then
            log_message "INFO" "Connection refresh successful"
            recovery_successful=1
            return 0
        fi
        
        REFRESH_COUNT=$((REFRESH_COUNT - 1))
        sed -i "s/REFRESH_COUNT=.*/REFRESH_COUNT=${REFRESH_COUNT}/" /etc/quecmanager/quecwatch/quecwatch.conf
        recovery_attempted=1
    fi

    [ ${recovery_successful} -eq 1 ] && return 0 || return 1
}

# Store initial SIM slot
initial_sim_slot=""
if [ "${AUTO_SIM_FAILOVER}" = "true" ]; then
    initial_sim_slot=$(get_current_sim)
    if [ $? -eq 0 ]; then
        log_message "INFO" "Auto SIM failover enabled. Initial SIM slot: ${initial_sim_slot}"
    else
        log_message "ERROR" "Failed to get initial SIM slot"
    fi
fi

# Main monitoring loop
failure_count=0
retry_trigger=$(load_retry_count)
sim_failover_interval=0

while true; do
    if ! check_internet; then
        failure_count=$((failure_count + 1))
        log_message "INFO" "Ping failed. Failure count: ${failure_count}"

        if [ ${failure_count} -ge ${PING_FAILURES} ]; then
            failure_count=0
            retry_trigger=$((retry_trigger + 1))
            update_retry_count ${retry_trigger}
            
            log_message "INFO" "Failure threshold reached. Retry trigger: ${retry_trigger}"

            if [ ${retry_trigger} -ge ${MAX_RETRIES} ]; then
                if [ "${AUTO_SIM_FAILOVER}" = "true" ]; then
                    log_message "INFO" "Max retries exhausted. Attempting SIM failover."
                    if switch_sim_card && check_internet; then
                        log_message "INFO" "SIM failover successful"
                        retry_trigger=0
                        failure_count=0
                        update_retry_count 0
                    else
                        log_message "ERROR" "SIM failover failed. Updating retry count before reboot."
                        retry_trigger=$((retry_trigger + 1))
                        update_retry_count ${retry_trigger}
                        log_message "INFO" "Updated retry count to ${retry_trigger}. Performing system reboot."
                        reboot
                    fi
                else
                    log_message "INFO" "Max retries exhausted. Auto SIM failover disabled. Removing QuecWatch."
                    # Clean up the retry count file
                    rm -f /etc/quecmanager/quecwatch/retry_count
                    # Remove from rc.local and disable
                    sed -i '\|/etc/quecmanager/quecwatch/quecwatch.sh|d' /etc/rc.local
                    sed -i 's/ENABLED=true/ENABLED=false/' /etc/quecmanager/quecwatch/quecwatch.conf
                    reboot
                    exit 0
                fi
            else
                if perform_connection_recovery; then
                    retry_trigger=0
                    failure_count=0
                    update_retry_count 0
                else
                    log_message "ERROR" "Recovery failed. Updating retry count before reboot."
                    retry_trigger=$((retry_trigger + 1))
                    update_retry_count ${retry_trigger}
                    log_message "INFO" "Updated retry count to ${retry_trigger}. Performing system reboot."
                    reboot
                fi
            fi
        fi
    else
        failure_count=0
        retry_trigger=0
        update_retry_count 0
        log_message "INFO" "Modem is connected to the internet"
        
        if [ "${AUTO_SIM_FAILOVER}" = "true" ] && [ "${SIM_FAILOVER_SCHEDULE}" -gt 0 ]; then
            current_sim_slot=$(get_current_sim)
            
            if [ -n "${initial_sim_slot}" ] && [ "${current_sim_slot}" != "${initial_sim_slot}" ]; then
                sim_failover_interval=$((sim_failover_interval + 1))
                
                if [ $((sim_failover_interval * PING_INTERVAL)) -ge $((SIM_FAILOVER_SCHEDULE * 60)) ]; then
                    log_message "INFO" "Scheduled check: Attempting to switch back to initial SIM ${initial_sim_slot}"
                    
                    if execute_at_command "AT+QUIMSLOT=${initial_sim_slot}"; then
                        sleep 10
                        
                        if check_internet; then
                            log_message "INFO" "Initial SIM restored successfully"
                            retry_trigger=0
                            failure_count=0
                            update_retry_count 0
                        else
                            log_message "WARN" "Initial SIM still not working. Switching back to backup SIM."
                            execute_at_command "AT+QUIMSLOT=${current_sim_slot}"
                            sleep 10
                        fi
                    else
                        log_message "ERROR" "Failed to switch to initial SIM"
                    fi
                    
                    sim_failover_interval=0
                fi
            fi
        fi
    fi

    sleep ${PING_INTERVAL}
done
EOL

    chmod +x "${QUECWATCH_SCRIPT}"

    # Run the script
    "${QUECWATCH_SCRIPT}" &
}

# Enable QuecWatch
enable_quecwatch() {
    initialize_config
    generate_monitoring_script

    if ! grep -q "${QUECWATCH_SCRIPT}" "${RCLOCAL}"; then
        [ -f "${RCLOCAL}" ] || touch "${RCLOCAL}"
        chmod +x "${RCLOCAL}"
        sed -i '$i'"${QUECWATCH_SCRIPT} &" "${RCLOCAL}"
    fi

    # Output success JSON
    echo '{"status": "success", "message": "QuecWatch enabled", "config": "'${QUECWATCH_CONFIG}'"}'
}

# Log debug information
{
    echo "Timestamp: $(date)"
    echo "Script Path: $0"
    echo "Ping Target: $ping_target"
    echo "Ping Interval: $ping_interval"
    echo "Ping Failures: $ping_failures"
    echo "Max Retries: $max_retries"
    echo "Connection Refresh: $connection_refresh"
    echo "Auto SIM Failover: $auto_sim_failover"
    echo "SIM Failover Schedule: $sim_failover_schedule"
} >>"$DEBUG_LOG_FILE" 2>&1

# Enable QuecWatch
enable_quecwatch

exit 0