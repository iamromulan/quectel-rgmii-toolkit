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
apnProfile1=$(echo "$QUERY_STRING" | sed -n 's/.*apnProfile1=\([^&]*\).*/\1/p' | tr -d "'")
pdpType1=$(echo "$QUERY_STRING" | sed -n 's/.*pdpType1=\([^&]*\).*/\1/p' | tr -d "'")
iccidProfile2=$(echo "$QUERY_STRING" | sed -n 's/.*iccidProfile2=\([^&]*\).*/\1/p' | tr -d "'")
apnProfile2=$(echo "$QUERY_STRING" | sed -n 's/.*apnProfile2=\([^&]*\).*/\1/p' | tr -d "'")
pdpType2=$(echo "$QUERY_STRING" | sed -n 's/.*pdpType2=\([^&]*\).*/\1/p' | tr -d "'")

# URL decode the values
iccidProfile1=$(urldecode "$iccidProfile1")
apnProfile1=$(urldecode "$apnProfile1")
pdpType1=$(urldecode "$pdpType1")
iccidProfile2=$(urldecode "$iccidProfile2")
apnProfile2=$(urldecode "$apnProfile2")
pdpType2=$(urldecode "$pdpType2")

echo "Content-type: application/json"
echo ""

# Validate required first profile
if [ -z "$iccidProfile1" ] || [ -z "$apnProfile1" ] || [ -z "$pdpType1" ]; then
    echo '{"status": "error", "message": "Profile 1 is required"}'
    exit 1
fi

# Function to log messages
log_message() {
    local level="$1"
    local message="$2"
    local LOG_DIR="/tmp/log/apnprofile"
    local LOG_FILE="${LOG_DIR}/apnprofile.log"
    
    mkdir -p "${LOG_DIR}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} - [${level}] ${message}" >> "$LOG_FILE"
    logger -t apnprofile "${level}: ${message}"
}

# Create required directories
mkdir -p /www/cgi-bin/services
mkdir -p /etc/init.d

# Function to create service script
create_service_script() {
    cat > /www/cgi-bin/services/apnprofile.sh <<'EOL'
#!/bin/sh

# Load UCI functions
. /lib/functions.sh

# Define file paths
QUEUE_FILE="/tmp/at_pipe.txt"
LOG_DIR="/tmp/log/apnprofile"
LOG_FILE="${LOG_DIR}/apnprofile.log"
PID_FILE="/var/run/apnprofile.pid"
STATE_FILE="/tmp/apnprofile_state.json"

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
    logger -t apnprofile "${level}: ${message}"
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

# Set APN with error handling
set_apn() {
    local pdp_type="$1"
    local apn="$2"
    
    if [ -z "$pdp_type" ] || [ -z "$apn" ]; then
        return 1
    fi
    
    if execute_at_command "AT+CGDCONT=1,\"$pdp_type\",\"$apn\";+COPS=2;+COPS=0"; then
        return 0
    fi
    return 1
}

# Function to get current configuration hash
get_config_hash() {
    config_load quecmanager
    local hash_input=""
    
    # Get Profile 1
    config_get ICCID_PROFILE1 apn_profile iccid_profile1
    config_get APN_PROFILE1 apn_profile apn_profile1
    config_get PDP_TYPE1 apn_profile pdp_type1
    
    # Get Profile 2
    config_get ICCID_PROFILE2 apn_profile iccid_profile2
    config_get APN_PROFILE2 apn_profile apn_profile2
    config_get PDP_TYPE2 apn_profile pdp_type2
    
    hash_input="${ICCID_PROFILE1}${APN_PROFILE1}${PDP_TYPE1}${ICCID_PROFILE2}${APN_PROFILE2}${PDP_TYPE2}"
    echo "$hash_input" | md5sum | cut -d' ' -f1
}

# Function to read state file
read_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "{}"
    fi
}

# Function to write state file
write_state() {
    local current_iccid="$1"
    local config_hash="$2"
    local status="$3"
    
    printf '{"iccid":"%s","config_hash":"%s","status":"%s","timestamp":"%s"}' \
        "$current_iccid" "$config_hash" "$status" "$(date '+%Y-%m-%d %H:%M:%S')" > "$STATE_FILE"
}

# Main service loop
while true; do
    # Get current state
    current_state=$(read_state)
    current_iccid=$(get_current_iccid)
    config_hash=$(get_config_hash)
    
    # Extract values from current state
    state_iccid=$(echo "$current_state" | sed -n 's/.*"iccid":"\([^"]*\)".*/\1/p')
    state_hash=$(echo "$current_state" | sed -n 's/.*"config_hash":"\([^"]*\)".*/\1/p')
    
    needs_update=0
    
    # Check if update is needed
    if [ ! -f "$STATE_FILE" ]; then
        log_message "INFO" "No state file found, will apply profile"
        needs_update=1
    elif [ "$current_iccid" != "$state_iccid" ]; then
        log_message "INFO" "ICCID changed from $state_iccid to $current_iccid"
        needs_update=1
    elif [ "$config_hash" != "$state_hash" ]; then
        log_message "INFO" "Configuration changed"
        needs_update=1
    fi
    
    if [ $needs_update -eq 1 ] && [ -n "$current_iccid" ]; then
        config_load quecmanager
        
        # Get Profile 1
        config_get ICCID_PROFILE1 apn_profile iccid_profile1
        config_get APN_PROFILE1 apn_profile apn_profile1
        config_get PDP_TYPE1 apn_profile pdp_type1
        
        # Get Profile 2
        config_get ICCID_PROFILE2 apn_profile iccid_profile2
        config_get APN_PROFILE2 apn_profile apn_profile2
        config_get PDP_TYPE2 apn_profile pdp_type2
        
        if [ "${current_iccid}" = "${ICCID_PROFILE1}" ]; then
            if set_apn "$PDP_TYPE1" "$APN_PROFILE1"; then
                log_message "INFO" "Successfully applied Profile 1"
                write_state "$current_iccid" "$config_hash" "success"
            else
                log_message "ERROR" "Failed to apply Profile 1"
                write_state "$current_iccid" "$config_hash" "error"
            fi
        elif [ -n "$ICCID_PROFILE2" ] && [ "${current_iccid}" = "${ICCID_PROFILE2}" ]; then
            if set_apn "$PDP_TYPE2" "$APN_PROFILE2"; then
                log_message "INFO" "Successfully applied Profile 2"
                write_state "$current_iccid" "$config_hash" "success"
            else
                log_message "ERROR" "Failed to apply Profile 2"
                write_state "$current_iccid" "$config_hash" "error"
            fi
        else
            log_message "INFO" "No matching ICCID profile found"
            write_state "$current_iccid" "$config_hash" "no_match"
        fi
    fi
    
    sleep 10
done
EOL

    chmod 755 /www/cgi-bin/services/apnprofile.sh
}

# Function to create init.d script
create_init_script() {
    cat > /etc/init.d/apnprofile-service <<'EOL'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
    local enabled
    
    # Check if service is enabled in UCI
    config_load quecmanager
    config_get enabled apn_profile enabled '0'
    
    [ "$enabled" != "1" ] && return 0
    
    procd_open_instance
    procd_set_param command /www/cgi-bin/services/apnprofile.sh
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

    chmod 755 /etc/init.d/apnprofile-service
}

# Initialize UCI configuration
touch /etc/config/quecmanager

# Remove existing APN profile section if it exists
uci -q delete quecmanager.apn_profile

# Create new APN profile section
uci set quecmanager.apn_profile=service
uci set quecmanager.apn_profile.enabled=1

# Set Profile 1 configuration
uci set quecmanager.apn_profile.iccid_profile1="$iccidProfile1"
uci set quecmanager.apn_profile.apn_profile1="$apnProfile1"
uci set quecmanager.apn_profile.pdp_type1="$pdpType1"

# Set Profile 2 configuration if provided
if [ -n "$iccidProfile2" ]; then
    uci set quecmanager.apn_profile.iccid_profile2="$iccidProfile2"
    uci set quecmanager.apn_profile.apn_profile2="$apnProfile2"
    uci set quecmanager.apn_profile.pdp_type2="$pdpType2"
fi

# Commit UCI changes
if ! uci commit quecmanager; then
    log_message "ERROR" "Failed to save UCI configuration"
    echo '{"status": "error", "message": "Failed to save UCI configuration"}'
    exit 1
fi

log_message "INFO" "UCI configuration saved successfully"

# Create service script if it doesn't exist
if [ ! -f "/www/cgi-bin/services/apnprofile.sh" ]; then
    create_service_script
    log_message "INFO" "Created service script"
fi

# Create init.d script if it doesn't exist
if [ ! -f "/etc/init.d/apnprofile-service" ]; then
    create_init_script
    log_message "INFO" "Created init.d script"
fi

# Enable and start the service
/etc/init.d/apnprofile-service enable
if /etc/init.d/apnprofile-service restart; then
    log_message "INFO" "Service started successfully"
    echo '{"status": "success", "message": "APN profiles saved and service started"}'
else
    log_message "ERROR" "Failed to start service"
    echo '{"status": "error", "message": "Failed to start service"}'
fi