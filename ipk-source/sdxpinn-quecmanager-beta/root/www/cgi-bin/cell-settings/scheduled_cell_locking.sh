#!/bin/sh

# Configuration
CONFIG_FILE="/etc/cell_lock_schedule.conf"
STATUS_FILE="/tmp/cell_lock_status"
CELL_LOCK_SCRIPT="/usr/bin/set_cell_lock.sh"

# Function to create set_cell_lock.sh script
create_cell_lock_script() {
    # Only create the script if it doesn't exist
    if [ ! -f "$CELL_LOCK_SCRIPT" ]; then
        cat >"$CELL_LOCK_SCRIPT" <<'EOL'
#!/bin/sh
ACTION=$1
LTE_PARAMS=$2
NR5G_PARAMS=$3

case "$ACTION" in
    enable)
        # Enable LTE lock if parameters exist
        if [ -n "$LTE_PARAMS" ]; then
            echo "AT+QNWLOCK=\"common/4g\",$LTE_PARAMS" | atinout - /dev/smd11 -
        fi
        
        # Enable NR5G lock if parameters exist
        if [ -n "$NR5G_PARAMS" ]; then
            echo "AT+QNWLOCK=\"common/5g\",$NR5G_PARAMS" | atinout - /dev/smd11 -
        fi
        ;;
        
    disable)
        # Disable LTE lock
        echo 'AT+QNWLOCK="common/4g",0' | atinout - /dev/smd11 -
        
        # Disable NR5G lock
        echo 'AT+QNWLOCK="common/5g",0' | atinout - /dev/smd11 -
        ;;
        
    *)
        echo "Invalid action"
        exit 1
        ;;
esac

# Restart network registration to apply changes
echo "AT+COPS=2" | atinout - /dev/smd11 -
sleep 2
echo "AT+COPS=0" | atinout - /dev/smd11 -
exit 0
EOL

        # Make the script executable
        chmod +x "$CELL_LOCK_SCRIPT"
    fi
}

# Function to remove set_cell_lock.sh script
remove_cell_lock_script() {
    if [ -f "$CELL_LOCK_SCRIPT" ]; then
        rm "$CELL_LOCK_SCRIPT"
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
}

# Function to disable scheduling
disable_scheduling() {
    if [ -f "$CONFIG_FILE" ]; then
        sed -i 's/ENABLED=1/ENABLED=0/' "$CONFIG_FILE"
    fi
    # Remove any existing cron jobs
    crontab -l | grep -v "set_cell_lock.sh" | crontab -
    # Remove the set_cell_lock.sh script
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
    # Read POST data
    read -r POST_DATA

    # Check if disabling is requested
    echo "$POST_DATA" | grep -q "disable=true"
    if [ $? -eq 0 ]; then
        disable_scheduling
        echo "Status: 200 OK"
        echo "Content-Type: application/json"
        echo ""
        echo "{\"status\":\"success\",\"message\":\"Scheduling disabled\"}"
        exit 0
    fi

    # Extract start and end times
    START_TIME=$(echo "$POST_DATA" | grep -o 'start_time=[^&]*' | cut -d'=' -f2)
    END_TIME=$(echo "$POST_DATA" | grep -o 'end_time=[^&]*' | cut -d'=' -f2)

    # Decode times
    START_TIME=$(urldecode "$START_TIME")
    END_TIME=$(urldecode "$END_TIME")

    # Validate times
    if [ -z "$START_TIME" ] || [ -z "$END_TIME" ]; then
        echo "Status: 400 Bad Request"
        echo "Content-Type: application/json"
        echo ""
        echo "{\"error\":\"Missing start or end time\"}"
        exit 1
    fi

    # Create set_cell_lock.sh script
    create_cell_lock_script

    # Convert times to cron format
    CRON_START=$(convert_to_cron_time "$START_TIME")
    CRON_END=$(convert_to_cron_time "$END_TIME")

    # Save configuration
    save_config "$START_TIME" "$END_TIME"

    # Check current cell lock status and get parameters
    LTE_STATUS=$(echo 'AT+QNWLOCK="common/4g"' | atinout - /dev/smd11 -)
    NR5G_STATUS=$(echo 'AT+QNWLOCK="common/5g"' | atinout - /dev/smd11 -)

    # Extract LTE parameters if locked
    LTE_PARAMS=$(echo "$LTE_STATUS" | grep -o '"common/4g",[^[:space:]]*' | cut -d',' -f2-)
    NR5G_PARAMS=$(echo "$NR5G_STATUS" | grep -o '"common/5g",[^[:space:]]*' | cut -d',' -f2-)

    # Create temporary file for new crontab
    TEMP_CRON=$(mktemp)

    # Get existing crontab entries (excluding our script)
    crontab -l 2>/dev/null | grep -v "set_cell_lock.sh" >"$TEMP_CRON"

    # Add new entries
    echo "$CRON_START * * * $CELL_LOCK_SCRIPT enable \"$LTE_PARAMS\" \"$NR5G_PARAMS\"" >>"$TEMP_CRON"
    echo "$CRON_END * * * $CELL_LOCK_SCRIPT disable" >>"$TEMP_CRON"

    # Install new crontab
    crontab "$TEMP_CRON"
    rm "$TEMP_CRON"

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
echo "Status: 400 Bad Request"
echo "Content-Type: application/json"
echo ""
echo "{\"error\":\"Invalid request\"}"
exit 1
