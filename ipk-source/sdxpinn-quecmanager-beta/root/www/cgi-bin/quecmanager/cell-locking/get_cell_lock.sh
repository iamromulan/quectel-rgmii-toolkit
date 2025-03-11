#!/bin/sh

# Set headers for JSON response
echo "Content-type: application/json"
echo ""

# Load UCI functions
. /lib/functions.sh

# Function to safely get UCI value with default
get_uci_value() {
    local value
    config_get value cell_lock "$1" "$2"
    echo "${value:-$2}"
}

# Function to check if daemon is running
check_service_status() {
    if [ -f "/var/run/cell_lock_scheduler.pid" ]; then
        pid=$(cat /var/run/cell_lock_scheduler.pid 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "running"
            return
        fi
    fi
    echo "stopped"
}

# Function to get current status with proper JSON handling
get_current_status() {
    local STATUS_FILE="/tmp/cell_lock_status.json"
    local status="unknown"
    local message="Status not available"
    local active="0"
    local locked="0"
    local timestamp=$(date +%s)
    
    if [ -f "$STATUS_FILE" ]; then
        # Try to extract values from status file
        if grep -q "status" "$STATUS_FILE"; then
            status=$(cat "$STATUS_FILE" | jsonfilter -e '@.status' 2>/dev/null)
            # Extract message and remove any surrounding quotes
            message=$(cat "$STATUS_FILE" | jsonfilter -e '@.message' 2>/dev/null | sed 's/^"//;s/"$//')
            active=$(cat "$STATUS_FILE" | jsonfilter -e '@.active' 2>/dev/null)
            locked=$(cat "$STATUS_FILE" | jsonfilter -e '@.locked' 2>/dev/null)
            timestamp=$(cat "$STATUS_FILE" | jsonfilter -e '@.timestamp' 2>/dev/null)
        fi
    fi
    
    # Escape quotes and special characters in message
    message=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
    
    # Return the status as a JSON object with properly quoted message
    echo "{\"status\":\"$status\",\"message\":\"$message\",\"active\":$active,\"locked\":$locked,\"timestamp\":$timestamp}"
}

# Load configuration
config_load quecmanager

# Check if cell lock section exists
if ! uci -q get quecmanager.cell_lock >/dev/null; then
    echo '{"status":"inactive","message":"Cell lock is not configured","enabled":false,"startTime":"","endTime":"","active":false,"locked":false}'
    exit 0
fi

# Get service status
service_status=$(check_service_status)

# Get current status
current_status=$(get_current_status)

# Get configuration values
enabled=$(get_uci_value "enabled" "0")
start_time=$(get_uci_value "start_time" "")
end_time=$(get_uci_value "end_time" "")
active=$(get_uci_value "active" "0")
lte_params=$(get_uci_value "lte_params" "")
nr5g_params=$(get_uci_value "nr5g_params" "")
lte_persist=$(get_uci_value "lte_persist" "0")
nr5g_persist=$(get_uci_value "nr5g_persist" "0")

# Convert numeric values to boolean for JSON
enabled_bool="false"
active_bool="false"
locked_bool="false"

[ "$enabled" = "1" ] && enabled_bool="true"
[ "$active" = "1" ] && active_bool="true"

# Get locked status from current_status
locked=$(echo "$current_status" | jsonfilter -e '@.locked' 2>/dev/null)
[ "$locked" = "1" ] && locked_bool="true"

# Extract the message properly from current status
message_value=$(echo "$current_status" | jsonfilter -e '@.message' 2>/dev/null | sed 's/^"//;s/"$//')

# Prepare JSON response in format expected by the component
cat <<EOF
{
    "enabled": $enabled_bool,
    "start_time": "$start_time",
    "end_time": "$end_time",
    "active": $active_bool,
    "status": "$(echo "$current_status" | jsonfilter -e '@.status')",
    "message": "$message_value",
    "locked": $locked_bool,
    "serviceStatus": "$service_status",
    "lteParams": "$lte_params",
    "nr5gParams": "$nr5g_params",
    "ltePersist": "$lte_persist",
    "nr5gPersist": "$nr5g_persist"
}
EOF