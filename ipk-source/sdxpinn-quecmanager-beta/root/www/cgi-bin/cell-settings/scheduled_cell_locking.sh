#!/bin/sh

# Configuration
CONFIG_FILE="/etc/cell_lock_schedule.conf"
STATUS_FILE="/tmp/cell_lock_status"
CELL_LOCK_SCRIPT="/usr/bin/set_cell_lock.sh"
QUEUE_FILE="/tmp/at_pipe.txt"
LOG_FILE="/tmp/cell_lock.log"

# Function to log messages
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} - [${level}] ${message}" >> "$LOG_FILE"
    logger -t cell_lock "${level}: ${message}"
}

# Function to handle AT command queue
handle_lock() {
    log_message "DEBUG" "Checking queue file status before lock"
    if [ ! -f "$QUEUE_FILE" ]; then
        log_message "DEBUG" "Queue file does not exist, creating it"
        touch "$QUEUE_FILE"
    fi
    
    # Clean any stale entries
    if grep -q "\"command\":\"AT_COMMAND\"" "$QUEUE_FILE"; then
        local wait_count=0
        while [ $wait_count -lt 6 ]; do
            if ! grep -q "\"command\":\"AT_COMMAND\"" "$QUEUE_FILE"; then
                break
            fi
            sleep 1
            wait_count=$((wait_count + 1))
        done
        [ $wait_count -eq 6 ] && sed -i "/\"command\":\"AT_COMMAND\"/d" "$QUEUE_FILE"
    fi
    
    printf '{"command":"AT_COMMAND","pid":"%s","timestamp":"%s"}\n' \
        "$$" \
        "$(date '+%H:%M:%S')" >> "$QUEUE_FILE"
}

# Function to execute AT command
execute_at_command() {
    local command="$1"
    local result=""
    
    log_message "DEBUG" "Executing AT command: ${command}"
    handle_lock
    
    result=$(sms_tool at "$command" -t 4 2>&1)
    local status=$?
    
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

# Function to create set_cell_lock.sh script
create_cell_lock_script() {
    if [ ! -f "$CELL_LOCK_SCRIPT" ]; then
        cat >"$CELL_LOCK_SCRIPT" <<'EOL'
#!/bin/sh

ACTION=$1
LTE_PARAMS=$2
NR5G_PARAMS=$3

QUEUE_FILE="/tmp/at_pipe.txt"
LOG_FILE="/tmp/cell_lock.log"

# Import common functions
. /etc/quecmanager/imei_profile/common_functions.sh || {
    echo "Failed to import common functions"
    exit 1
}

case "$ACTION" in
    enable)
        # Enable LTE lock if parameters exist
        if [ -n "$LTE_PARAMS" ]; then
            execute_at_command "AT+QNWLOCK=\"common/4g\",$LTE_PARAMS"
        fi
        
        # Enable NR5G lock if parameters exist
        if [ -n "$NR5G_PARAMS" ]; then
            execute_at_command "AT+QNWLOCK=\"common/5g\",$NR5G_PARAMS"
        fi
        ;;
        
    disable)
        # Disable LTE lock
        execute_at_command "AT+QNWLOCK=\"common/4g\",0"
        
        # Disable NR5G lock
        execute_at_command "AT+QNWLOCK=\"common/5g\",0"
        ;;
        
    *)
        log_message "ERROR" "Invalid action: $ACTION"
        exit 1
        ;;
esac

# Restart network registration to apply changes
execute_at_command "AT+COPS=2"
sleep 2
execute_at_command "AT+COPS=0"
exit 0
EOL

        chmod +x "$CELL_LOCK_SCRIPT"
        log_message "INFO" "Created cell lock script at $CELL_LOCK_SCRIPT"
    fi
}

# Function to remove set_cell_lock.sh script
remove_cell_lock_script() {
    if [ -f "$CELL_LOCK_SCRIPT" ]; then
        rm "$CELL_LOCK_SCRIPT"
        log_message "INFO" "Removed cell lock script"
    fi
}

# Function to urldecode
urldecode() {
    echo -e "$(echo "$1" | sed 's/+/ /g;s/%\([0-9A-F][0-9A-F]\)/\\x\1/g')"
}

# Function to convert HH:MM to cron format
convert_to_cron_time() {
    echo "$1" | awk -F: '{print $2, $1}'
}

# Function to save configuration
save_config() {
    echo "START_TIME=$1" >"$CONFIG_FILE"
    echo "END_TIME=$2" >>"$CONFIG_FILE"
    echo "ENABLED=1" >>"$CONFIG_FILE"
    log_message "INFO" "Saved configuration - Start: $1, End: $2"
}

# Function to disable scheduling
disable_scheduling() {
    if [ -f "$CONFIG_FILE" ]; then
        sed -i 's/ENABLED=1/ENABLED=0/' "$CONFIG_FILE"
        log_message "INFO" "Disabled scheduling"
    fi
    crontab -l | grep -v "set_cell_lock.sh" | crontab -
    remove_cell_lock_script
}

# Function to get current status
get_status() {
    if [ -f "$CONFIG_FILE" ]; then
        ENABLED=$(grep "ENABLED=" "$CONFIG_FILE" | cut -d'=' -f2)
        START_TIME=$(grep "START_TIME=" "$CONFIG_FILE" | cut -d'=' -f2)
        END_TIME=$(grep "END_TIME=" "$CONFIG_FILE" | cut -d'=' -f2)
        
        echo "Status: 200 OK"
        echo "Content-Type: application/json"
        echo ""
        echo "{\"enabled\":$ENABLED,\"start_time\":\"$START_TIME\",\"end_time\":\"$END_TIME\"}"
    else
        echo "Status: 200 OK"
        echo "Content-Type: application/json"
        echo ""
        echo "{\"enabled\":0,\"start_time\":\"\",\"end_time\":\"\"}"
    fi
}

# Handle POST requests
if [ "$REQUEST_METHOD" = "POST" ]; then
    read -r POST_DATA
    
    if echo "$POST_DATA" | grep -q "disable=true"; then
        disable_scheduling
        echo "Status: 200 OK"
        echo "Content-Type: application/json"
        echo ""
        echo "{\"status\":\"success\",\"message\":\"Scheduling disabled\"}"
        exit 0
    fi
    
    START_TIME=$(echo "$POST_DATA" | grep -o 'start_time=[^&]*' | cut -d'=' -f2)
    END_TIME=$(echo "$POST_DATA" | grep -o 'end_time=[^&]*' | cut -d'=' -f2)
    
    START_TIME=$(urldecode "$START_TIME")
    END_TIME=$(urldecode "$END_TIME")
    
    if [ -z "$START_TIME" ] || [ -z "$END_TIME" ]; then
        log_message "ERROR" "Missing start or end time"
        echo "Status: 400 Bad Request"
        echo "Content-Type: application/json"
        echo ""
        echo "{\"error\":\"Missing start or end time\"}"
        exit 1
    fi
    
    create_cell_lock_script
    
    CRON_START=$(convert_to_cron_time "$START_TIME")
    CRON_END=$(convert_to_cron_time "$END_TIME")
    
    save_config "$START_TIME" "$END_TIME"
    
    # Check current cell lock status and get parameters
    LTE_STATUS=$(execute_at_command 'AT+QNWLOCK="common/4g"')
    NR5G_STATUS=$(execute_at_command 'AT+QNWLOCK="common/5g"')
    
    LTE_PARAMS=$(echo "$LTE_STATUS" | grep -o '"common/4g",[^[:space:]]*' | cut -d',' -f2-)
    NR5G_PARAMS=$(echo "$NR5G_STATUS" | grep -o '"common/5g",[^[:space:]]*' | cut -d',' -f2-)
    
    TEMP_CRON=$(mktemp)
    
    crontab -l 2>/dev/null | grep -v "set_cell_lock.sh" >"$TEMP_CRON"
    
    echo "$CRON_START * * * $CELL_LOCK_SCRIPT enable \"$LTE_PARAMS\" \"$NR5G_PARAMS\"" >>"$TEMP_CRON"
    echo "$CRON_END * * * $CELL_LOCK_SCRIPT disable" >>"$TEMP_CRON"
    
    crontab "$TEMP_CRON"
    rm "$TEMP_CRON"
    
    log_message "INFO" "Scheduling enabled with start time $START_TIME and end time $END_TIME"
    
    echo "Status: 200 OK"
    echo "Content-Type: application/json"
    echo ""
    echo "{\"status\":\"success\",\"message\":\"Scheduling enabled\"}"
    exit 0
fi

# Parse query string for GET requests
if [ "$REQUEST_METHOD" = "GET" ]; then
    QUERY_STRING=$(echo "$QUERY_STRING" | sed 's/&/\n/g')
    for param in $QUERY_STRING; do
        case "$param" in
        status=*)
            get_status
            exit 0
            ;;
        esac
    done
fi

# If no valid request is made
log_message "ERROR" "Invalid request received"
echo "Status: 400 Bad Request"
echo "Content-Type: application/json"
echo ""
echo "{\"error\":\"Invalid request\"}"
exit 1