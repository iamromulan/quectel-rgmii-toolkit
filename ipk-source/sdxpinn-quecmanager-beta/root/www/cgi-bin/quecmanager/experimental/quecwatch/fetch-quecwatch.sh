#!/bin/sh

# Set headers for JSON response
echo "Content-type: application/json"
echo ""

# Load UCI functions
. /lib/functions.sh

# Function to safely get UCI value with default
get_uci_value() {
    local value
    config_get value quecwatch "$1" "$2"
    echo "${value:-$2}"
}

# Function to format boolean for JSON
format_boolean() {
    if [ "$1" = "1" ] || [ "$1" = "true" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Function to check if service is running
check_service_status() {
    if [ -f "/var/run/quecwatch.pid" ]; then
        pid=$(cat /var/run/quecwatch.pid 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "running"
            return
        fi
    fi
    echo "stopped"
}

# Function to get last log entry
get_last_log() {
    local LOG_FILE="/tmp/log/quecwatch/quecwatch.log"
    if [ -f "$LOG_FILE" ]; then
        tail -n 1 "$LOG_FILE" | sed 's/"/\\"/g'
    else
        echo "No log entries found"
    fi
}

# Function to get current status
get_current_status() {
    local STATUS_FILE="/tmp/quecwatch_status.json"
    local status="unknown"
    local message="Status not available"
    local retry="0"
    local maxRetries="0"
    local timestamp=$(date +%s)
    
    if [ -f "$STATUS_FILE" ]; then
        # Try to extract values from status file
        if grep -q "status" "$STATUS_FILE"; then
            status=$(cat "$STATUS_FILE" | jsonfilter -e '@.status' 2>/dev/null)
            message=$(cat "$STATUS_FILE" | jsonfilter -e '@.message' 2>/dev/null)
            retry=$(cat "$STATUS_FILE" | jsonfilter -e '@.retry' 2>/dev/null)
            maxRetries=$(cat "$STATUS_FILE" | jsonfilter -e '@.maxRetries' 2>/dev/null)
            timestamp=$(cat "$STATUS_FILE" | jsonfilter -e '@.timestamp' 2>/dev/null)
        fi
    fi
    
    # Use defaults if extraction failed
    [ -z "$status" ] && status="unknown"
    [ -z "$message" ] && message="Status not available"
    [ -z "$retry" ] && retry="0"
    [ -z "$maxRetries" ] && maxRetries="0"
    [ -z "$timestamp" ] && timestamp=$(date +%s)
    
    echo "{\"status\":\"$status\",\"message\":\"$message\",\"retry\":$retry,\"maxRetries\":$maxRetries,\"timestamp\":$timestamp}"
}

# Load QuecManager configuration
config_load quecmanager

# Check if QuecWatch section exists
if ! uci -q get quecmanager.quecwatch >/dev/null; then
    echo '{"status":"inactive","message":"QuecWatch is not configured"}'
    exit 0
fi

# Get enabled status
enabled=$(get_uci_value "enabled" "0")

# Get service status
service_status=$(check_service_status)

# Get current status
current_status=$(get_current_status)

# Get last log entry
last_log=$(get_last_log)

# Fetch all configuration values
ping_target=$(get_uci_value "ping_target" "8.8.8.8")
ping_interval=$(get_uci_value "ping_interval" "60")
ping_failures=$(get_uci_value "ping_failures" "3")
max_retries=$(get_uci_value "max_retries" "5")
current_retries=$(get_uci_value "current_retries" "0")
connection_refresh=$(format_boolean $(get_uci_value "connection_refresh" "false"))
refresh_count=$(get_uci_value "refresh_count" "3")
auto_sim_failover=$(format_boolean $(get_uci_value "auto_sim_failover" "false"))
sim_failover_schedule=$(get_uci_value "sim_failover_schedule" "0")

# Determine the overall status
status="inactive"
if [ "$enabled" = "1" ]; then
    if [ "$service_status" = "running" ]; then
        status="active"
    else
        status="error"
    fi
fi

# Prepare JSON response
cat <<EOF
{
    "status": "$status",
    "serviceStatus": "$service_status",
    "currentStatus": $current_status,
    "config": {
        "pingTarget": "$ping_target",
        "pingInterval": $ping_interval,
        "pingFailures": $ping_failures,
        "maxRetries": $max_retries,
        "currentRetries": $current_retries,
        "connectionRefresh": $connection_refresh,
        "refreshCount": $refresh_count,
        "autoSimFailover": $auto_sim_failover,
        "simFailoverSchedule": $sim_failover_schedule
    },
    "lastActivity": "$last_log"
}
EOF