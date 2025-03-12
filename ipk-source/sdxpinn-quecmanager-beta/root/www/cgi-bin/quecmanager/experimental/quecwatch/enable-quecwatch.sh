#!/bin/sh

# Set content type to JSON
echo "Content-type: application/json"
echo ""

# Read POST data
read -r POST_DATA

# Function to extract value from JSON post data
extract_json_value() {
    local key="$1"
    local default="$2"
    
    # Try with jsonfilter
    if command -v jsonfilter >/dev/null 2>&1; then
        local value=$(echo "$POST_DATA" | jsonfilter -e "@.$key" 2>/dev/null)
        [ -n "$value" ] && echo "$value" && return 0
    fi
    
    # Fallback to grep
    local value=$(echo "$POST_DATA" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | cut -d'"' -f4)
    [ -n "$value" ] && echo "$value" && return 0
    
    # Fallback to grep for numbers and booleans
    local value=$(echo "$POST_DATA" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9a-zA-Z]*" | cut -d':' -f2 | tr -d '[:space:]')
    [ -n "$value" ] && echo "$value" && return 0
    
    # Return default value
    echo "$default"
    return 0
}

# Extract parameters from POST data
ping_target=$(extract_json_value "pingTarget" "8.8.8.8")
ping_interval=$(extract_json_value "pingInterval" "60")
ping_failures=$(extract_json_value "pingFailures" "3")
max_retries=$(extract_json_value "maxRetries" "5")
connection_refresh=$(extract_json_value "connectionRefresh" "false")
auto_sim_failover=$(extract_json_value "autoSimFailover" "false")
sim_failover_schedule=$(extract_json_value "simFailoverSchedule" "0")

# Validate numeric values
validate_number() {
    local value="$1"
    local min="$2"
    local max="$3"
    local name="$4"
    
    if ! echo "$value" | grep -q '^[0-9]\+$'; then
        echo '{"status":"error","message":"'"$name must be a number"'"}'
        exit 1
    fi
    
    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo '{"status":"error","message":"'"$name must be between $min and $max"'"}'
        exit 1
    fi
}

# Validate boolean values
validate_boolean() {
    local value="$1"
    local name="$2"
    
    if [ "$value" != "true" ] && [ "$value" != "false" ]; then
        echo '{"status":"error","message":"'"$name must be true or false"'"}'
        exit 1
    fi
}

# Validate parameters
validate_number "$ping_interval" 5 3600 "Ping interval"
validate_number "$ping_failures" 1 10 "Ping failures"
validate_number "$max_retries" 1 20 "Max retries"
validate_number "$sim_failover_schedule" 0 1440 "SIM failover schedule"
validate_boolean "$connection_refresh" "Connection refresh"
validate_boolean "$auto_sim_failover" "Auto SIM failover"

# Function to setup UCI configuration
setup_uci_config() {
    # Create section if it doesn't exist
    touch /etc/config/quecmanager
    
    if ! uci -q get quecmanager.quecwatch >/dev/null; then
        uci set quecmanager.quecwatch=service
    fi
    
    # Set UCI values
    uci set quecmanager.quecwatch.enabled='1'
    uci set quecmanager.quecwatch.ping_target="$ping_target"
    uci set quecmanager.quecwatch.ping_interval="$ping_interval"
    uci set quecmanager.quecwatch.ping_failures="$ping_failures"
    uci set quecmanager.quecwatch.max_retries="$max_retries"
    uci set quecmanager.quecwatch.current_retries='0'
    uci set quecmanager.quecwatch.connection_refresh="$connection_refresh"
    uci set quecmanager.quecwatch.refresh_count='3'
    uci set quecmanager.quecwatch.auto_sim_failover="$auto_sim_failover"
    uci set quecmanager.quecwatch.sim_failover_schedule="$sim_failover_schedule"
    
    # Commit changes
    if ! uci commit quecmanager; then
        echo '{"status":"error","message":"Failed to save configuration"}'
        exit 1
    fi
    
    return 0
}

# Setup configuration
if ! setup_uci_config; then
    exit 1
fi

# Enable and start the service
if [ ! -f "/etc/init.d/quecwatch" ]; then
    echo '{"status":"error","message":"QuecWatch service script not found"}'
    exit 1
fi

# Make sure the service script is executable
chmod +x /etc/init.d/quecwatch

# Enable the service
if ! /etc/init.d/quecwatch enable; then
    echo '{"status":"error","message":"Failed to enable QuecWatch service"}'
    exit 1
fi

# Start the service
if ! /etc/init.d/quecwatch start; then
    echo '{"status":"error","message":"Failed to start QuecWatch service"}'
    exit 1
fi

# Return success response
echo '{"status":"success","message":"QuecWatch enabled successfully"}'