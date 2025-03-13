#!/bin/sh

# Set headers for JSON response
echo "Content-type: application/json"
echo ""

# Load UCI functions
. /lib/functions.sh

# Function to safely get UCI value with default
get_uci_value() {
    local value
    config_get value apn_profile "$1" "$2"
    echo "${value:-$2}"
}

# Function to check if service is running
check_service_status() {
    if [ -f "/var/run/apnprofile.pid" ]; then
        pid=$(cat /var/run/apnprofile.pid)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "running"
            return
        fi
    fi
    
    # Double check using process search
    if pgrep -f "/www/cgi-bin/services/apnprofile.sh" >/dev/null; then
        echo "running"
        return
    fi
    
    echo "stopped"
}

# Function to get last log entry
get_last_log() {
    local LOG_FILE="/tmp/log/apnprofile/apnprofile.log"
    if [ -f "$LOG_FILE" ]; then
        tail -n 1 "$LOG_FILE"
    else
        echo "No log entries found"
    fi
}

# Function to check if init.d service is enabled
check_service_enabled() {
    if [ -f "/etc/init.d/apnprofile-service" ]; then
        if /etc/init.d/apnprofile-service enabled; then
            echo "true"
            return
        fi
    fi
    echo "false"
}

# Load QuecManager configuration
config_load quecmanager

# Check if APN Profile section exists
if ! uci -q get quecmanager.apn_profile >/dev/null; then
    echo '{"status": "inactive", "message": "APN Profile service is not configured"}'
    exit 0
fi

# Get enabled status from UCI
enabled=$(get_uci_value "enabled" "0")

if [ "$enabled" != "1" ]; then
    echo '{"status": "inactive", "message": "APN Profile service is disabled"}'
    exit 0
fi

# Check if service script exists
if [ ! -f "/www/cgi-bin/services/apnprofile.sh" ]; then
    echo '{"status": "error", "message": "Service script is missing"}'
    exit 0
fi

# Get service status information
service_status=$(check_service_status)
service_enabled=$(check_service_enabled)
last_log=$(get_last_log)

# Fetch all configuration values from UCI
iccid_profile1=$(get_uci_value "iccid_profile1" "")
apn_profile1=$(get_uci_value "apn_profile1" "")
pdp_type1=$(get_uci_value "pdp_type1" "")
iccid_profile2=$(get_uci_value "iccid_profile2" "")
apn_profile2=$(get_uci_value "apn_profile2" "")
pdp_type2=$(get_uci_value "pdp_type2" "")

# Function to check if profile data exists
validate_profile_data() {
    local iccid="$1"
    local apn="$2"
    local pdp="$3"
    
    [ -n "$iccid" ] && [ -n "$apn" ] && [ -n "$pdp" ]
}

# Build JSON response
cat <<EOF
{
    "status": "active",
    "service": {
        "status": "${service_status}",
        "enabled": ${service_enabled},
        "script": "$([ -f "/www/cgi-bin/services/apnprofile.sh" ] && echo "present" || echo "missing")",
        "initScript": "$([ -f "/etc/init.d/apnprofile-service" ] && echo "present" || echo "missing")"
    },
    "profiles": {
EOF

# Add Profile 1 if it exists
if validate_profile_data "$iccid_profile1" "$apn_profile1" "$pdp_type1"; then
    cat <<EOF
        "profile1": {
            "iccid": "${iccid_profile1}",
            "apn": "${apn_profile1}",
            "pdpType": "${pdp_type1}"
        }
EOF
fi

# Add Profile 2 if it exists
if validate_profile_data "$iccid_profile2" "$apn_profile2" "$pdp_type2"; then
    # Add comma if Profile 1 was added
    [ -n "$iccid_profile1" ] && echo ","
    cat <<EOF
        "profile2": {
            "iccid": "${iccid_profile2}",
            "apn": "${apn_profile2}",
            "pdpType": "${pdp_type2}"
        }
EOF
fi

# Close the profiles object and add last activity
cat <<EOF
    },
    "lastActivity": "${last_log}"
}
EOF