#!/bin/sh

# Parse POST data (using busybox compatible method)
read -r QUERY_STRING

# Function to urldecode (busybox compatible version)
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

# Create directory with proper permissions
mkdir -p /etc/quecmanager/imei_profile
chmod 755 /etc/quecmanager/imei_profile

# Create a configuration file to store IMEI profiles
cat > /etc/quecmanager/imei_profile/imei_config.txt <<EOF
iccidProfile1=${iccidProfile1}
imeiProfile1=${imeiProfile1}
EOF

# Add second profile only if ICCID is provided
if [ -n "$iccidProfile2" ]; then
    cat >> /etc/quecmanager/imei_profile/imei_config.txt <<EOF
iccidProfile2=${iccidProfile2}
imeiProfile2=${imeiProfile2}
EOF
fi
chmod 644 /etc/quecmanager/imei_profile/imei_config.txt

# Create the imeiProfiles.sh script with proper locking mechanism and logging
cat > /etc/quecmanager/imei_profile/imeiProfiles.sh <<'EOF'
#!/bin/sh

# Define file paths
QUEUE_FILE="/tmp/at_pipe.txt"
LOG_FILE="/tmp/imei_profiles.log"
[ ! -f "${QUEUE_FILE}" ] && touch "${QUEUE_FILE}"

# Enhanced logging function with debug level
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} - [${level}] ${message}" >> "$LOG_FILE"
    logger -t imei_profiles "${level}: ${message}"
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

# Simplified lock handling with debug
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

# Execute AT command without timeout dependency
execute_at_command() {
    local command="$1"
    local result=""
    
    log_message "DEBUG" "Executing AT command: ${command}"
    handle_lock
    
    # Execute command and capture all output
    result=$(sms_tool at "$command" -t 4 2>&1)
    local status=$?
    
    log_message "DEBUG" "Removing our entry from queue"
    sed -i "/\"pid\":\"$$\"/d" "$QUEUE_FILE"
    
    if [ $status -ne 0 ]; then
        log_message "ERROR" "Command failed with status $status: $command"
        log_message "ERROR" "Command output: $result"
        return 1
    fi
    
    log_message "DEBUG" "Command successful. Output: $result"
    echo "$result"
    return 0
}

# Get current ICCID with enhanced debug
get_current_iccid() {
    local result
    local retry_count=0
    local max_retries=3
    
    log_message "INFO" "Attempting to get current ICCID"
    
    while [ $retry_count -lt $max_retries ]; do
        log_message "DEBUG" "ICCID attempt ${retry_count}"
        result=$(execute_at_command "AT+ICCID")
        local cmd_status=$?
        
        log_message "DEBUG" "AT+ICCID command returned status: ${cmd_status}"
        log_message "DEBUG" "AT+ICCID raw output: ${result}"
        
        if [ $cmd_status -eq 0 ] && echo "$result" | grep -q "+ICCID:"; then
            local iccid=$(echo "$result" | grep "+ICCID:" | cut -d' ' -f2 | tr -d '[:space:]')
            log_message "INFO" "Retrieved current ICCID: ${iccid}"
            echo "${iccid}"
            return 0
        else
            log_message "WARN" "Attempt ${retry_count} failed to get valid ICCID"
            log_message "WARN" "Result: ${result}"
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            log_message "INFO" "Waiting 2 seconds before retry"
            sleep 2
        fi
    done
    
    log_message "ERROR" "Failed to get ICCID after $max_retries attempts"
    return 1
}

# Get current IMEI with enhanced debug
get_current_imei() {
    local result
    local retry_count=0
    local max_retries=3
    
    log_message "INFO" "Attempting to get current IMEI"
    
    while [ $retry_count -lt $max_retries ]; do
        log_message "DEBUG" "IMEI attempt ${retry_count}"
        result=$(execute_at_command "AT+CGSN")
        local cmd_status=$?
        
        log_message "DEBUG" "AT+CGSN command returned status: ${cmd_status}"
        log_message "DEBUG" "AT+CGSN raw output: ${result}"
        
        if [ $cmd_status -eq 0 ]; then
            local imei=$(echo "$result" | grep -v "AT+CGSN" | grep -v "OK" | tr -d '\r\n[:space:]')
            if [ -n "$imei" ]; then
                log_message "INFO" "Retrieved current IMEI: ${imei}"
                echo "${imei}"
                return 0
            fi
        fi
        
        log_message "WARN" "Attempt ${retry_count} failed to get valid IMEI"
        retry_count=$((retry_count + 1))
        [ $retry_count -lt $max_retries ] && sleep 2
    done
    
    log_message "ERROR" "Failed to get IMEI after $max_retries attempts"
    return 1
}

# Set IMEI with enhanced debug
set_imei() {
    local imei="$1"
    local retry_count=0
    local max_retries=3
    
    log_message "INFO" "Attempting to set IMEI: ${imei}"
    
    while [ $retry_count -lt $max_retries ]; do
        log_message "DEBUG" "IMEI set attempt ${retry_count}"
        result=$(execute_at_command "AT+EGMR=1,7,\"$imei\";+QPOWD=1")
        local cmd_status=$?
        
        log_message "DEBUG" "AT+EGMR command returned status: ${cmd_status}"
        log_message "DEBUG" "AT+EGMR raw output: ${result}"
        
        if [ $cmd_status -eq 0 ] && echo "$result" | grep -q "OK"; then
            log_message "INFO" "Successfully set IMEI: ${imei}"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        [ $retry_count -lt $max_retries ] && sleep 2
    done
    
    log_message "ERROR" "Failed to set IMEI after $max_retries attempts"
    return 1
}

# Load configuration
if [ -f /etc/quecmanager/imei_profile/imei_config.txt ]; then
    . /etc/quecmanager/imei_profile/imei_config.txt
    log_message "INFO" "Loaded configuration - Profile1 ICCID: ${iccidProfile1}, IMEI: ${imeiProfile1}"
    [ -n "$iccidProfile2" ] && log_message "INFO" "Profile2 ICCID: ${iccidProfile2}, IMEI: ${imeiProfile2}"
else
    log_message "ERROR" "Configuration file not found"
    echo "Configuration file not found" > /tmp/imei_result.txt
    exit 1
fi

# Get current ICCID and IMEI
current_iccid=$(get_current_iccid)
current_imei=$(get_current_imei)

if [ $? -ne 0 ]; then
    log_message "ERROR" "Failed to get current ICCID or IMEI"
    echo "Failed to get current ICCID or IMEI" > /tmp/imei_result.txt
    exit 1
fi

log_message "INFO" "Current ICCID: ${current_iccid}"
log_message "INFO" "Current IMEI: ${current_imei}"

# Match ICCID and apply corresponding profile
if [ "${current_iccid}" = "${iccidProfile1}" ]; then
    log_message "INFO" "Matched with Profile1"
    if [ "${current_imei}" != "${imeiProfile1}" ]; then
        log_message "INFO" "IMEI needs updating for Profile1"
        if set_imei "${imeiProfile1}"; then
            echo "IMEI set successfully" > /tmp/imei_result.txt
        else
            echo "Failed to set IMEI" > /tmp/imei_result.txt
        fi
    else
        log_message "INFO" "IMEI already matches Profile1"
        echo "IMEI already correct" > /tmp/imei_result.txt
    fi
elif [ -n "${iccidProfile2}" ] && [ "${current_iccid}" = "${iccidProfile2}" ]; then
    log_message "INFO" "Matched with Profile2"
    if [ "${current_imei}" != "${imeiProfile2}" ]; then
        log_message "INFO" "IMEI needs updating for Profile2"
        if set_imei "${imeiProfile2}"; then
            echo "IMEI set successfully" > /tmp/imei_result.txt
        else
            echo "Failed to set IMEI" > /tmp/imei_result.txt
        fi
    else
        log_message "INFO" "IMEI already matches Profile2"
        echo "IMEI already correct" > /tmp/imei_result.txt
    fi
else
    log_message "WARN" "No matching ICCID profile found"
    echo "No matching ICCID profile found" > /tmp/imei_result.txt
fi
EOF

# Make the script executable
chmod 755 /etc/quecmanager/imei_profile/imeiProfiles.sh

# Add to rc.local if not already present
if ! grep -q "^[^#]*\/etc\/quecmanager\/imei_profile\/imeiProfiles.sh" /etc/rc.local; then
    sed -i '/^exit 0/i /etc/quecmanager/imei_profile/imeiProfiles.sh' /etc/rc.local
fi

# Run the script immediately
/etc/quecmanager/imei_profile/imeiProfiles.sh

# Check the result
if [ -f /tmp/imei_result.txt ]; then
    result=$(cat /tmp/imei_result.txt)
    rm -f /tmp/imei_result.txt

    case "$result" in
        "IMEI set successfully")
            echo '{"status": "success", "message": "IMEI profiles saved and applied successfully"}'
            ;;
        "IMEI already correct")
            echo '{"status": "success", "message": "IMEI profiles saved, no changes needed"}'
            ;;
        "No matching ICCID profile found")
            echo '{"status": "warning", "message": "IMEI profiles saved but no matching ICCID found"}'
            ;;
        "Configuration file not found")
            echo '{"status": "error", "message": "Configuration file not found"}'
            ;;
        "Failed to get current ICCID or IMEI")
            echo '{"status": "error", "message": "Failed to get current ICCID or IMEI"}'
            ;;
        *)
            echo '{"status": "error", "message": "IMEI profiles saved but failed to apply"}'
            ;;
    esac
else
    echo '{"status": "error", "message": "Something went wrong while processing IMEI profiles"}'
fi