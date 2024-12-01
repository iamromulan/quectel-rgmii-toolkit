#!/bin/sh

# Set headers for JSON response
echo "Content-type: application/json"
echo ""

# Configuration file path
CONFIG_FILE="/etc/quecmanager/quecwatch/quecwatch.conf"

# Check if configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo '{"status": "inactive", "message": "QuecWatch is not configured"}'
    exit 0
fi

# Function to safely get config value
get_config_value() {
    grep "^$1=" "$CONFIG_FILE" | cut -d'=' -f2
}

# Check if QuecWatch is enabled
enabled=$(get_config_value "ENABLED")
if [ "$enabled" != "true" ]; then
    echo '{"status": "inactive", "message": "QuecWatch is disabled"}'
    exit 0
fi

# Fetch configuration values
ping_target=$(get_config_value "PING_TARGET")
ping_interval=$(get_config_value "PING_INTERVAL")
ping_failures=$(get_config_value "PING_FAILURES")
max_retries=$(get_config_value "MAX_RETRIES")
current_retries=$(get_config_value "CURRENT_RETRIES")
connection_refresh=$(get_config_value "CONNECTION_REFRESH")
refresh_count=$(get_config_value "REFRESH_COUNT")

# Check monitoring script existence
QUECWATCH_SCRIPT="/etc/quecmanager/quecwatch/quecwatch.sh"
if [ ! -f "$QUECWATCH_SCRIPT" ]; then
    echo '{"status": "error", "message": "Monitoring script is missing"}'
    exit 0
fi

# Check log file for recent activity
LOG_FILE="/tmp/log/quecwatch/quecwatch.log"
last_log=""
if [ -f "$LOG_FILE" ]; then
    last_log=$(tail -n 1 "$LOG_FILE")
fi

# Prepare JSON response
cat <<EOF
{
    "status": "active",
    "config": {
        "pingTarget": "${ping_target}",
        "pingInterval": ${ping_interval},
        "pingFailures": ${ping_failures},
        "maxRetries": ${max_retries},
        "currentRetries": ${current_retries},
        "connectionRefresh": ${connection_refresh},
        "refreshCount": ${refresh_count:-0}
    },
    "lastActivity": "${last_log}"
}
EOF