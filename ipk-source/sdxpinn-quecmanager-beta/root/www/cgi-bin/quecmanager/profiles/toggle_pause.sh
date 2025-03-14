#!/bin/sh
# Location: /www/cgi-bin/quecmanager/profiles/toggle_pause.sh

# Set content type to JSON
echo -n ""
echo "Content-type: application/json"
echo ""

# Configuration
CHECK_TRIGGER="/tmp/quecprofiles_check"
STATUS_FILE="/tmp/quecprofiles_status.json"
TRACK_FILE="/tmp/quecprofiles_active"

# Function to log messages
log_message() {
    local level="${2:-info}"
    logger -t quecprofiles -p "daemon.$level" "toggle_pause: $1"
}

# Function to update status file directly - used when pausing a profile
update_status_to_paused() {
    local profile_name="$1"
    
    # Create JSON status for paused profile
    cat > "$STATUS_FILE" <<EOF
{
    "status": "paused",
    "message": "Profile is paused. Resume the profile to apply settings.",
    "profile": "$profile_name",
    "progress": 0,
    "timestamp": $(date +%s)
}
EOF

    # Create simple track file for easy checking
    echo "paused:$profile_name:0" > "$TRACK_FILE"
    chmod 644 "$TRACK_FILE" "$STATUS_FILE"
    
    log_message "Status updated: paused - Profile is paused ($profile_name)" "info"
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

# Function to toggle pause state
toggle_pause_state() {
    local profile_index="$1"
    local paused="$2"  # 0 or 1
    local profile_name=$(uci -q get quecprofiles.$profile_index.name)
    
    # Update the profile in UCI config
    uci -q batch <<EOF
set quecprofiles.$profile_index.paused='$paused'
commit quecprofiles
EOF
    
    # Check if the operation was successful
    if [ $? -eq 0 ]; then
        if [ "$paused" = "1" ]; then
            log_message "Successfully paused profile '$profile_name'" "info"
            # Immediately update status to paused without waiting for daemon
            update_status_to_paused "$profile_name"
            return 0
        else
            log_message "Successfully resumed profile '$profile_name'" "info"
            # Touch the check trigger file to force daemon to check ASAP
            touch "$CHECK_TRIGGER"
            chmod 644 "$CHECK_TRIGGER"
            log_message "Triggered profile check for resumed profile '$profile_name'" "info"
            return 0
        fi
    else
        log_message "Failed to update pause state for profile '$profile_name'" "error"
        return 1
    fi
}

# Output debug info
log_message "Received toggle pause request" "debug"

# Ensure UCI config exists
if [ ! -f /etc/config/quecprofiles ]; then
    log_message "quecprofiles config does not exist" "error"
    output_json "error" "Configuration file not found"
fi

# Get POST data
iccid=""
paused=""

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
            paused=$(echo "$POST_DATA" | jsonfilter -e '@.paused' 2>/dev/null)
        else
            # If jsonfilter is not available, try basic parsing
            iccid=$(echo "$POST_DATA" | grep -o '"iccid":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
            paused=$(echo "$POST_DATA" | grep -o '"paused":[0-1]' | head -1 | cut -d':' -f2)
        fi
    else
        log_message "No content length specified" "error"
        output_json "error" "No data received"
    fi
elif [ -n "$QUERY_STRING" ]; then
    # URL parameters for GET requests (for testing)
    iccid=$(echo "$QUERY_STRING" | grep -o 'iccid=[^&]*' | cut -d'=' -f2)
    paused=$(echo "$QUERY_STRING" | grep -o 'paused=[^&]*' | cut -d'=' -f2)
    
    # URL decode values
    iccid=$(echo "$iccid" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
    
    log_message "Using URL parameters: iccid=$iccid, paused=$paused" "debug"
fi

# Sanitize inputs
iccid=$(sanitize "${iccid:-}")
paused=$(sanitize "${paused:-}")

# Validate required inputs
if [ -z "$iccid" ]; then
    log_message "ICCID is missing" "error"
    output_json "error" "ICCID is required to identify the profile"
fi

# Validate pause state (must be 0 or 1)
if [ "$paused" != "0" ] && [ "$paused" != "1" ]; then
    log_message "Invalid paused state: $paused" "error"
    output_json "error" "Paused state must be 0 (resumed) or 1 (paused)"
fi

# Find profile to toggle
profile_index=$(find_profile_by_iccid "$iccid")
if [ $? -ne 0 ]; then
    log_message "Profile with ICCID $iccid not found" "error"
    output_json "error" "Profile not found"
fi

# Get profile info for response
profile_name=$(uci -q get quecprofiles.$profile_index.name)

# Toggle pause state
if toggle_pause_state "$profile_index" "$paused"; then
    if [ "$paused" = "1" ]; then
        log_message "Profile paused successfully: $profile_name" "info"
        output_json "success" "Profile paused successfully" "{\"iccid\":\"$iccid\",\"name\":\"$profile_name\",\"paused\":true}"
    else
        log_message "Profile resumed successfully: $profile_name" "info"
        output_json "success" "Profile resumed successfully" "{\"iccid\":\"$iccid\",\"name\":\"$profile_name\",\"paused\":false}"
    fi
else
    log_message "Failed to update pause state for profile: $profile_name" "error"
    output_json "error" "Failed to update profile status. Please check system logs."
fi