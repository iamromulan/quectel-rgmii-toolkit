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

# URL decode the values
action=$(urldecode "$action")
ping_target=$(urldecode "$ping_target")
ping_interval=$(urldecode "$ping_interval")
ping_failures=$(urldecode "$ping_failures")
max_retries=$(urldecode "$max_retries")
connection_refresh=$(urldecode "$connection_refresh")

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

    # Write configuration with defaults
    cat >"${QUECWATCH_CONFIG}" <<EOL
PING_TARGET=${ping_target}
PING_INTERVAL=${ping_interval:-30}
PING_FAILURES=${ping_failures:-3}
MAX_RETRIES=${max_retries:-5}
CONNECTION_REFRESH=${connection_refresh:-false}
CURRENT_RETRIES=0
REFRESH_COUNT=${connection_refresh:+1}
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

# Initialize failure and retry counters
failure_count=0
retry_trigger=0

# Ensure CURRENT_RETRIES starts at 0
update_retry_count 0

while true; do
    # Ping the target
    if ! ping -c ${PING_FAILURES} ${PING_TARGET} > /dev/null 2>&1; then
        failure_count=$((failure_count + 1))
        log_event "Ping failed. Failure count: ${failure_count}"

        # Check if failure threshold is reached
        if [ ${failure_count} -ge ${PING_FAILURES} ]; then
            # Reset failure count
            failure_count=0
            retry_trigger=$((retry_trigger + 1))
            
            # Update retry count in config
            update_retry_count ${retry_trigger}
            
            log_event "Failure threshold reached. Retry trigger: ${retry_trigger}"

            # Check if retry threshold is reached
            if [ ${retry_trigger} -ge ${MAX_RETRIES} ]; then
                log_event "Max retries exhausted. Removing QuecWatch."
                
                # Remove the script from rc.local
                sed -i '\|/etc/quecmanager/quecwatch/quecwatch.sh|d' /etc/rc.local
                
                # Perform final system reboot
                reboot
                exit 0
            fi

            # Connection refresh logic
            if [ "${CONNECTION_REFRESH}" = "true" ] && [ "${REFRESH_COUNT}" -gt 0 ]; then
                # Decrement refresh count
                . /etc/quecmanager/quecwatch/quecwatch.conf
                REFRESH_COUNT=$((REFRESH_COUNT - 1))
                
                # Update config
                sed -i "s/REFRESH_COUNT=.*/REFRESH_COUNT=${REFRESH_COUNT}/" /etc/quecmanager/quecwatch/quecwatch.conf
                
                log_event "Attempting connection refresh"
                # Add your modem connection refresh command here
                echo AT+COPS=2 | atinout - /dev/smd7 -
                sleep 2
                echo AT+COPS=0 | atinout - /dev/smd7 -

                # Verify connection after refresh
                if ! ping -c 3 ${PING_TARGET} > /dev/null 2>&1; then
                    log_event "Connection refresh failed. Continuing with retry process."
                    # Continue with retry process, no premature reboot or script removal
                else
                    log_event "Connection refresh successful"
                    # Reset retry trigger if connection is restored
                    retry_trigger=0
                    failure_count=0
                    update_retry_count 0
                fi
            else
                # Perform modem reboot
                log_event "Rebooting modem. Retry attempts: ${retry_trigger}"
                # Add your modem reboot command here
                reboot
            fi
        fi
    else
        # Reset failure count and retry trigger if connection is good
        log_event "Modem is connected to the internet"
        failure_count=0
        retry_trigger=0
        update_retry_count 0
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
} >>"$DEBUG_LOG_FILE" 2>&1

# Enable QuecWatch
enable_quecwatch

exit 0