#!/bin/sh

# Configuration
CONFIG_FILE="/etc/keep_alive_schedule.conf"
STATUS_FILE="/tmp/keep_alive_status"
SPEEDTEST_SCRIPT="/www/cgi-bin/home/speedtest/speedtest.sh"

# Function to convert HH:MM to minutes since midnight
time_to_minutes() {
    echo "$1" | awk -F: '{print $1 * 60 + $2}'
}

# Function to validate time interval
validate_interval() {
    START_TIME=$1
    END_TIME=$2
    INTERVAL_MINUTES=$3

    # Convert times to minutes
    START_MINUTES=$(time_to_minutes "$START_TIME")
    END_MINUTES=$(time_to_minutes "$END_TIME")

    # Calculate duration between start and end time
    if [ $END_MINUTES -lt $START_MINUTES ]; then
        # Handle case where end time is on the next day
        DURATION=$((1440 - START_MINUTES + END_MINUTES))
    else
        DURATION=$((END_MINUTES - START_MINUTES))
    fi

    # Check if interval is longer than duration
    if [ $INTERVAL_MINUTES -gt $DURATION ]; then
        return 1
    fi
    return 0
}

# Function to generate cron time expression
generate_cron_time() {
    START_TIME=$1
    END_TIME=$2
    INTERVAL=$3

    START_HOUR=$(echo "$START_TIME" | cut -d: -f1 | sed 's/^0//')
    START_MIN=$(echo "$START_TIME" | cut -d: -f2)
    END_HOUR=$(echo "$END_TIME" | cut -d: -f1 | sed 's/^0//')
    END_MIN=$(echo "$END_TIME" | cut -d: -f2)

    # If end time is less than start time, it means we cross midnight
    if [ $(time_to_minutes "$END_TIME") -lt $(time_to_minutes "$START_TIME") ]; then
        # Create two cron entries for before and after midnight
        echo "*/$INTERVAL $START_HOUR-23 * * * $SPEEDTEST_SCRIPT"
        echo "*/$INTERVAL 0-$((END_HOUR - 1)) * * * $SPEEDTEST_SCRIPT"
    else
        echo "*/$INTERVAL $START_HOUR-$((END_HOUR - 1)) * * * $SPEEDTEST_SCRIPT"
    fi
}

# Function to urldecode
urldecode() {
    echo -e "$(echo "$1" | sed 's/+/ /g;s/%\([0-9A-F][0-9A-F]\)/\\x\1/g')"
}

# Function to save configuration
save_config() {
    echo "START_TIME=$1" >"$CONFIG_FILE"
    echo "END_TIME=$2" >>"$CONFIG_FILE"
    echo "INTERVAL=$3" >>"$CONFIG_FILE"
    echo "ENABLED=1" >>"$CONFIG_FILE"
}

# Function to disable scheduling
disable_scheduling() {
    if [ -f "$CONFIG_FILE" ]; then
        sed -i 's/ENABLED=1/ENABLED=0/' "$CONFIG_FILE"
    fi
    # Remove any existing cron jobs
    crontab -l | grep -v "$SPEEDTEST_SCRIPT" | crontab -
}

# Function to get current status
get_status() {
    if [ -f "$CONFIG_FILE" ]; then
        ENABLED=$(grep "ENABLED=" "$CONFIG_FILE" | cut -d'=' -f2)
        START_TIME=$(grep "START_TIME=" "$CONFIG_FILE" | cut -d'=' -f2)
        END_TIME=$(grep "END_TIME=" "$CONFIG_FILE" | cut -d'=' -f2)
        INTERVAL=$(grep "INTERVAL=" "$CONFIG_FILE" | cut -d'=' -f2)

        echo "Status: 200 OK"
        echo "Content-Type: application/json"
        echo ""
        echo "{\"enabled\":$ENABLED,\"start_time\":\"$START_TIME\",\"end_time\":\"$END_TIME\",\"interval\":$INTERVAL}"
    else
        echo "Status: 200 OK"
        echo "Content-Type: application/json"
        echo ""
        echo "{\"enabled\":0,\"start_time\":\"\",\"end_time\":\"\",\"interval\":0}"
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

    # Extract times and interval
    START_TIME=$(echo "$POST_DATA" | grep -o 'start_time=[^&]*' | cut -d'=' -f2)
    END_TIME=$(echo "$POST_DATA" | grep -o 'end_time=[^&]*' | cut -d'=' -f2)
    INTERVAL=$(echo "$POST_DATA" | grep -o 'interval=[^&]*' | cut -d'=' -f2)

    # Decode times
    START_TIME=$(urldecode "$START_TIME")
    END_TIME=$(urldecode "$END_TIME")
    INTERVAL=$(urldecode "$INTERVAL")

    # Validate times
    if [ -z "$START_TIME" ] || [ -z "$END_TIME" ] || [ -z "$INTERVAL" ]; then
        echo "Status: 400 Bad Request"
        echo "Content-Type: application/json"
        echo ""
        echo "{\"error\":\"Missing start time, end time, or interval\"}"
        exit 1
    fi

    # Validate interval is a number
    if ! echo "$INTERVAL" | grep -q '^[0-9]\+$'; then
        echo "Status: 400 Bad Request"
        echo "Content-Type: application/json"
        echo ""
        echo "{\"error\":\"Interval must be a number in minutes\"}"
        exit 1
    fi

    # Validate interval
    if ! validate_interval "$START_TIME" "$END_TIME" "$INTERVAL"; then
        echo "Status: 400 Bad Request"
        echo "Content-Type: application/json"
        echo ""
        echo "{\"error\":\"Interval is longer than the time between start and end time\"}"
        exit 1
    fi

    # Create temporary file for new crontab
    TEMP_CRON=$(mktemp)

    # Get existing crontab entries (excluding our script)
    crontab -l 2>/dev/null | grep -v "$SPEEDTEST_SCRIPT" >"$TEMP_CRON"

    # Generate and add cron entries
    generate_cron_time "$START_TIME" "$END_TIME" "$INTERVAL" >>"$TEMP_CRON"

    # Install new crontab
    crontab "$TEMP_CRON"
    rm "$TEMP_CRON"

    # Save configuration
    save_config "$START_TIME" "$END_TIME" "$INTERVAL"

    echo "Status: 200 OK"
    echo "Content-Type: application/json"
    echo ""
    echo "{\"status\":\"success\",\"message\":\"Keep-alive scheduling enabled\"}"
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