#!/bin/sh
# Location: /www/cgi-bin/quecmanager/profiles/quec_profile_delete.sh

# Set content type to JSON
echo -n ""
echo "Content-type: application/json"
echo ""

# Function to log messages
log_message() {
    local level="${2:-info}"
    logger -t quecprofiles -p "daemon.$level" "delete: $1"
}

# Function to output JSON response
output_json() {
    local status="$1"
    local message="$2"
    local data="${3:-{}}"
    
    printf '{"status":"%s","message":"%s","data":%s}\n' "$status" "$message" "$data"
    exit 0
}

# Function to sanitize input
sanitize() {
    echo "$1" | tr -d '\r\n' | sed 's/[^a-zA-Z0-9,.:_-]//g'
}

# Function to find profile by ICCID
find_profile_by_iccid() {
    local iccid="$1"
    # Get all profile indices
    local profile_indices=$(uci show quecprofiles | grep -o '@profile\[[0-9]\+\]' | sort -u)
    
    for profile_index in $profile_indices; do
        local current_iccid=$(uci -q get quecprofiles.$profile_index.iccid)
        if [ "$current_iccid" = "$iccid" ]; then
            echo "$profile_index"
            return 0
        fi
    done
    
    return 1
}

# Function to delete a profile
delete_profile() {
    local profile_index="$1"
    local profile_name=$(uci -q get quecprofiles.$profile_index.name)
    
    # Delete the profile from UCI config
    uci -q batch <<EOF
delete quecprofiles.$profile_index
commit quecprofiles
EOF
    
    # Check if the operation was successful
    if [ $? -eq 0 ]; then
        log_message "Successfully deleted profile '$profile_name'" "info"
        return 0
    else
        log_message "Failed to delete profile '$profile_name'" "error"
        return 1
    fi
}

# Output debug info
log_message "Received delete profile request" "debug"

# Ensure UCI config exists
if [ ! -f /etc/config/quecprofiles ]; then
    log_message "quecprofiles config does not exist" "error"
    output_json "error" "Configuration file not found"
fi

# Get ICCID from request
iccid=""

if [ "$REQUEST_METHOD" = "POST" ]; then
    # Get content length
    CONTENT_LENGTH=$(echo "$CONTENT_LENGTH" | tr -cd '0-9')
    
    if [ -n "$CONTENT_LENGTH" ]; then
        # Read POST data
        POST_DATA=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null)
        
        # Debug log
        log_message "Received POST data: $POST_DATA" "debug"
        
        # Parse JSON with jsonfilter if available
        if command -v jsonfilter >/dev/null 2>&1; then
            iccid=$(echo "$POST_DATA" | jsonfilter -e '@.iccid' 2>/dev/null)
        else
            # If jsonfilter is not available, try basic parsing
            iccid=$(echo "$POST_DATA" | grep -o '"iccid":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
        fi
    else
        log_message "No content length specified" "error"
        output_json "error" "No data received"
    fi
elif [ -n "$QUERY_STRING" ]; then
    # URL parameters for GET or DELETE requests
    iccid=$(echo "$QUERY_STRING" | grep -o 'iccid=[^&]*' | cut -d'=' -f2)
    
    # URL decode value
    iccid=$(echo "$iccid" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
    
    log_message "Using URL parameter: iccid=$iccid" "debug"
fi

# Sanitize input
iccid=$(sanitize "${iccid:-}")

# Validate ICCID
if [ -z "$iccid" ]; then
    log_message "ICCID is missing" "error"
    output_json "error" "ICCID is required to identify the profile"
fi

# Find profile to delete
profile_index=$(find_profile_by_iccid "$iccid")
if [ $? -ne 0 ]; then
    log_message "Profile with ICCID $iccid not found" "error"
    output_json "error" "Profile not found"
fi

# Get profile info for response
profile_name=$(uci -q get quecprofiles.$profile_index.name)

# Delete the profile
if delete_profile "$profile_index"; then
    log_message "Profile deleted successfully: $profile_name" "info"
    output_json "success" "Profile deleted successfully" "{\"iccid\":\"$iccid\",\"name\":\"$profile_name\"}"
else
    log_message "Failed to delete profile: $profile_name" "error"
    output_json "error" "Failed to delete profile. Please check system logs."
fi