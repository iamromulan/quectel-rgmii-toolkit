#!/bin/sh

# Read POST data
read -r QUERY_STRING

# Function to urldecode
urldecode() {
    local value="$1"
    value="${value//+/ }"
    value="${value//%/\\x}"
    printf '%b' "$value"
}

# Extract values from POST data
iccidProfile1=$(echo "$QUERY_STRING" | sed -n 's/.*iccidProfile1=\([^&]*\).*/\1/p' | tr -d "'")
imeiProfile1=$(echo "$QUERY_STRING" | sed -n 's/.*imeiProfile1=\([^&]*\).*/\1/p' | tr -d "'")
iccidProfile2=$(echo "$QUERY_STRING" | sed -n 's/.*iccidProfile2=\([^&]*\).*/\1/p' | tr -d "'")
imeiProfile2=$(echo "$QUERY_STRING" | sed -n 's/.*imeiProfile2=\([^&]*\).*/\1/p' | tr -d "'")

# URL decode the values
iccidProfile1=$(urldecode "$iccidProfile1")
imeiProfile1=$(urldecode "$imeiProfile1")
iccidProfile2=$(urldecode "$iccidProfile2")
imeiProfile2=$(urldecode "$imeiProfile2")

echo "Content-type: application/json"
echo ""

# Validate required first profile
if [ -z "$iccidProfile1" ] || [ -z "$imeiProfile1" ]; then
    echo '{"status": "error", "message": "Profile 1 is required"}'
    exit 1
fi

# Function to log messages
log_message() {
    local level="$1"
    local message="$2"
    local LOG_DIR="/tmp/log/imeiprofile"
    local LOG_FILE="${LOG_DIR}/imeiprofile.log"
    
    mkdir -p "${LOG_DIR}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} - [${level}] ${message}" >> "$LOG_FILE"
    logger -t imeiprofile "${level}: ${message}"
}

# Create required directories
mkdir -p /www/cgi-bin/services

# Function to create service script
create_service_script() {
    cat > /www/cgi-bin/services/imeiprofile.sh <<'EOL'
#!/bin/sh

# Load UCI functions
. /lib/functions.sh

# Define file paths
QUEUE_FILE="/tmp/at_pipe.txt"
LOG_DIR="/tmp/log/imeiprofile"
LOG_FILE="${LOG_DIR}/imeiprofile.log"
PID_FILE="/var/run/imeiprofile.pid"

mkdir -p "${LOG_DIR}"
[ ! -f "${QUEUE_FILE}" ] && touch "${QUEUE_FILE}"

# Save PID
echo $$ > "${PID_FILE}"

# Enhanced logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} - [${level}] ${message}" >> "$LOG_FILE"
    logger -t imeiprofile "${level}: ${message}"
}

# AT command handling with locking
handle_lock() {
    local max_wait=30
    local wait_count=0
    
    while [ -f "$QUEUE_FILE" ] && grep -q "AT_COMMAND" "$QUEUE_FILE" && [ $wait_count -lt $max_wait ]; do
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    printf '{"command":"AT_COMMAND","pid":"%s","timestamp":"%s"}\n' "$$" "$(date '+%H:%M:%S')" >> "$QUEUE_FILE"
}

# Execute AT command with retries
execute_at_command() {
    local command="$1"
    local result=""
    local retry_count=0
    local max_retries=3
    
    while [ $retry_count -lt $max_retries ]; do
        handle_lock
        result=$(sms_tool at "$command" -t 4 2>&1)
        local status=$?
        sed -i "/\"pid\":\"$$\"/d" "$QUEUE_FILE"
        
        if [ $status -eq 0 ] && [ -n "$result" ]; then
            echo "$result"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        [ $retry_count -lt $max_retries ] && sleep 2
    done
    
    return 1
}

# Get current ICCID
get_current_iccid() {
    local result=$(execute_at_command "AT+ICCID")
    if [ $? -eq 0 ] && echo "$result" | grep -q "+ICCID:"; then
        echo "$result" | grep "+ICCID:" | cut -d' ' -f2 | tr -d '[:space:]'
        return 0
    fi
    return 1
}

# Get current IMEI
get_current_imei() {
    local result=$(execute_at_command "AT+CGSN")
    if [ $? -eq 0 ]; then
        echo "$result" | grep -v "AT+CGSN" | grep -v "OK" | tr -d '\r\n[:space:]'
        return 0
    fi
    return 1
}

# Set IMEI
set_imei() {
    local imei="$1"
    if execute_at_command "AT+EGMR=1,7,\"$imei\";+QPOWD=1"; then
        return 0
    fi
    return 1
}

# Function to safely get UCI value with default
get_uci_value() {
    local value
    config_get value imei_profile "$1" "$2"
    echo "${value:-$2}"
}

# Main service loop
while true; do
    # Load current configuration
    config_load quecmanager
    
    # Get Profile 1
    iccid_profile1=$(get_uci_value "iccid_profile1")
    imei_profile1=$(get_uci_value "imei_profile1")
    
    # Get Profile 2
    iccid_profile2=$(get_uci_value "iccid_profile2")
    imei_profile2=$(get_uci_value "imei_profile2")
    
    # Get current ICCID and IMEI
    current_iccid=$(get_current_iccid)
    current_imei=$(get_current_imei)
    
    if [ $? -eq 0 ] && [ -n "$current_iccid" ] && [ -n "$current_imei" ]; then
        if [ "${current_iccid}" = "${iccid_profile1}" ]; then
            if [ "${current_imei}" != "${imei_profile1}" ]; then
                if set_imei "${imei_profile1}"; then
                    log_message "INFO" "Successfully applied Profile 1 IMEI"
                else
                    log_message "ERROR" "Failed to apply Profile 1 IMEI"
                fi
            fi
        elif [ -n "$iccid_profile2" ] && [ "${current_iccid}" = "${iccid_profile2}" ]; then
            if [ "${current_imei}" != "${imei_profile2}" ]; then
                if set_imei "${imei_profile2}"; then
                    log_message "INFO" "Successfully applied Profile 2 IMEI"
                else
                    log_message "ERROR" "Failed to apply Profile 2 IMEI"
                fi
            fi
        else
            log_message "INFO" "No matching ICCID profile found"
        fi
    else
        log_message "ERROR" "Failed to get current ICCID or IMEI"
    fi
    
    sleep 30
done
EOL

    chmod 755 /www/cgi-bin/services/imeiprofile.sh
}

# Function to create init.d script
create_init_script() {
    cat > /etc/init.d/imeiprofile-service <<'EOL'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
    local enabled
    
    # Check if service is enabled in UCI
    config_load quecmanager
    config_get enabled imei_profile enabled '0'
    
    [ "$enabled" != "1" ] && return 0
    
    procd_open_instance
    procd_set_param command /www/cgi-bin/services/imeiprofile.sh
    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-5}
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param nice 19
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "quecmanager"
}

reload_service() {
    stop
    start
}
EOL

    chmod 755 /etc/init.d/imeiprofile-service
}

# Initialize UCI configuration
touch /etc/config/quecmanager

# Remove existing IMEI profile section if it exists
uci -q delete quecmanager.imei_profile

# Create new IMEI profile section
uci set quecmanager.imei_profile=service
uci set quecmanager.imei_profile.enabled=1

# Set Profile 1 configuration
uci set quecmanager.imei_profile.iccid_profile1="$iccidProfile1"
uci set quecmanager.imei_profile.imei_profile1="$imeiProfile1"

# Set Profile 2 configuration if provided
if [ -n "$iccidProfile2" ]; then
    uci set quecmanager.imei_profile.iccid_profile2="$iccidProfile2"
    uci set quecmanager.imei_profile.imei_profile2="$imeiProfile2"
fi

# Commit UCI changes
if ! uci commit quecmanager; then
    log_message "ERROR" "Failed to save UCI configuration"
    echo '{"status": "error", "message": "Failed to save UCI configuration"}'
    exit 1
fi

log_message "INFO" "UCI configuration saved successfully"

# Create service script if it doesn't exist
if [ ! -f "/www/cgi-bin/services/imeiprofile.sh" ]; then
    create_service_script
    log_message "INFO" "Created service script"
fi

# Create init.d script if it doesn't exist
if [ ! -f "/etc/init.d/imeiprofile-service" ]; then
    create_init_script
    log_message "INFO" "Created init.d script"
fi

# Enable and start the service
/etc/init.d/imeiprofile-service enable
if /etc/init.d/imeiprofile-service restart; then
    log_message "INFO" "Service started successfully"
    echo '{"status": "success", "message": "IMEI profiles saved and service started"}'
else
    log_message "ERROR" "Failed to start service"
    echo '{"status": "error", "message": "Failed to start service"}'
fi
