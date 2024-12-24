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

# Log directory
LOG_DIR="/tmp/log/quecwatch"
mkdir -p "${LOG_DIR}"

# Function to log events
log_event() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_DIR}/quecwatch.log"
}

# Function to update retry count in config
update_retry_count() {
    local new_retry_count=$1
    sed -i "s/CURRENT_RETRIES=[0-9]*/CURRENT_RETRIES=${new_retry_count}/" /etc/quecmanager/quecwatch/quecwatch.conf
    # Reload config to ensure latest values
    . /etc/quecmanager/quecwatch/quecwatch.conf
}

# Function to get current SIM slot
get_current_sim() {
    echo AT+QUIMSLOT? | atinout - /dev/smd11 /tmp/log/quecwatch/current_sim.txt
    grep "+QUIMSLOT:" /tmp/log/quecwatch/current_sim.txt | awk '{print $2}'
}

# Function to switch SIM card
switch_sim_card() {
    log_event "Attempting to switch SIM card"
    
    # Get current SIM slot
    current_sim_slot=$(get_current_sim)
    
    # Toggle between SIM slots (assuming 2 SIM slots)
    if [ "${current_sim_slot}" = "1" ]; then
        new_sim_slot=2
    else
        new_sim_slot=1
    fi
    
    log_event "Switching from SIM slot ${current_sim_slot} to SIM slot ${new_sim_slot}"
    echo "AT+QUIMSLOT=${new_sim_slot}" | atinout - /dev/smd11 -
    sleep 10  # Give more time for SIM switch and network registration
    
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

    # Try Connection Refresh if enabled
    if [ "${CONNECTION_REFRESH}" = "true" ] && [ "${retry_trigger}" -eq 1 ] && [ "${REFRESH_COUNT}" -gt 0 ]; then
        log_event "Attempting connection refresh"
        echo AT+COPS=2 | atinout - /dev/smd11 -
        sleep 2
        echo AT+COPS=0 | atinout - /dev/smd11 -
        sleep 5
        
        if check_internet; then
            log_event "Connection refresh successful"
            recovery_successful=1
            return 0
        fi
        
        REFRESH_COUNT=$((REFRESH_COUNT - 1))
        sed -i "s/REFRESH_COUNT=.*/REFRESH_COUNT=${REFRESH_COUNT}/" /etc/quecmanager/quecwatch/quecwatch.conf
        recovery_attempted=1
    fi

    [ ${recovery_successful} -eq 1 ] && return 0 || return 1
}

# Store initial SIM slot only if auto SIM failover is enabled
initial_sim_slot=""
if [ "${AUTO_SIM_FAILOVER}" = "true" ]; then
    initial_sim_slot=$(get_current_sim)
    log_event "Auto SIM failover enabled. Initial SIM slot: ${initial_sim_slot}"
fi

# Main loop
failure_count=0
retry_trigger=0
sim_failover_interval=0

while true; do
    # Check internet connectivity
    if ! check_internet; then
        failure_count=$((failure_count + 1))
        log_event "Ping failed. Failure count: ${failure_count}"

        # Check if failure threshold is reached
        if [ ${failure_count} -ge ${PING_FAILURES} ]; then
            failure_count=0
            retry_trigger=$((retry_trigger + 1))
            update_retry_count ${retry_trigger}
            
            log_event "Failure threshold reached. Retry trigger: ${retry_trigger}"

            # Check if retry threshold is reached
            if [ ${retry_trigger} -ge ${MAX_RETRIES} ]; then
                # Only attempt SIM failover if enabled
                if [ "${AUTO_SIM_FAILOVER}" = "true" ]; then
                    log_event "Max retries exhausted. Auto SIM failover is enabled. Attempting SIM failover."
                    switch_sim_card
                    
                    if check_internet; then
                        log_event "SIM failover successful"
                        retry_trigger=0
                        failure_count=0
                        update_retry_count 0
                    else
                        log_event "SIM failover failed. Performing system reboot."
                        reboot
                    fi
                else
                    # If auto SIM failover is not enabled, follow original behavior
                    log_event "Max retries exhausted. Auto SIM failover is disabled. Removing QuecWatch."
                    sed -i '\|/etc/quecmanager/quecwatch/quecwatch.sh|d' /etc/rc.local
                    reboot
                    exit 0
                fi
            else
                # Attempt connection recovery
                if perform_connection_recovery; then
                    retry_trigger=0
                    failure_count=0
                    update_retry_count 0
                else
                    log_event "Recovery failed. Performing system reboot."
                    reboot
                fi
            fi
        fi
    else
        # Reset failure count and retry trigger if connection is good
        failure_count=0
        retry_trigger=0
        update_retry_count 0
        log_event "Modem is connected to the internet"
        
        # Only check SIM schedule if auto SIM failover is enabled
        if [ "${AUTO_SIM_FAILOVER}" = "true" ] && [ "${SIM_FAILOVER_SCHEDULE}" -gt 0 ]; then
            current_sim_slot=$(get_current_sim)
            
            # Only proceed with schedule check if we're on the backup SIM
            if [ -n "${initial_sim_slot}" ] && [ "${current_sim_slot}" != "${initial_sim_slot}" ]; then
                sim_failover_interval=$((sim_failover_interval + 1))
                
                # Check if schedule interval has passed
                if [ $((sim_failover_interval * PING_INTERVAL)) -ge $((SIM_FAILOVER_SCHEDULE * 60)) ]; then
                    log_event "Scheduled check: Attempting to switch back to initial SIM ${initial_sim_slot}"
                    
                    # Switch to initial SIM
                    echo "AT+QUIMSLOT=${initial_sim_slot}" | atinout - /dev/smd11 -
                    sleep 10
                    
                    # Check if initial SIM works
                    if check_internet; then
                        log_event "Initial SIM restored successfully"
                        retry_trigger=0
                        failure_count=0
                        update_retry_count 0
                    else
                        log_event "Initial SIM still not working. Switching back to backup SIM."
                        echo "AT+QUIMSLOT=${current_sim_slot}" | atinout - /dev/smd11 -
                        sleep 10
                    fi
                    
                    # Reset interval counter
                    sim_failover_interval=0
                fi
            fi
        fi
    fi

    # Wait for specified interval before next check
    sleep ${PING_INTERVAL}
done
EOL

    chmod +x "${QUECWATCH_SCRIPT}"

    # Run the script
    "${QUECWATCH_SCRIPT}" &
}

# Enable QuecWatch
enable_quecwatch() {
    # Initialize configuration
    initialize_config

    # Generate monitoring script
    generate_monitoring_script

    # Add to rc.local if not already present
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