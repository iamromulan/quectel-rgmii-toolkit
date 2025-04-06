#!/bin/sh
# Location: /www/cgi-bin/quecmanager/profiles/check_status.cgi

# Set content type to JSON
echo "Content-type: application/json"
echo ""

# Configuration
STATUS_FILE="/tmp/quecprofiles_status.json"
TRACK_FILE="/tmp/quecprofiles_active"

# Function to log messages
log_message() {
    local level="${2:-info}"
    logger -t quecprofiles -p "daemon.$level" "status_check: $1"
}

# Function to output default "idle" JSON
output_idle_json() {
    cat <<EOF
{
    "status": "idle",
    "message": "No active profile operations",
    "profile": "unknown",
    "progress": 0,
    "timestamp": $(date +%s)
}
EOF
    exit 0
}

# Check if status file exists
if [ -f "$STATUS_FILE" ]; then
    # Check if file is not empty
    if [ -s "$STATUS_FILE" ]; then
        # Cat the entire file content (more reliable than grep)
        status_content=$(cat "$STATUS_FILE")
        
        # Log content for debugging
        log_message "Status file content: $status_content" "debug"
        
        # Check if it looks like valid JSON
        if echo "$status_content" | grep -q "status"; then
            # Output the status file content
            cat "$STATUS_FILE"
            
            # Extract status for logging only
            status=$(echo "$status_content" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
            log_message "Status from file: $status" "info"
            exit 0
        else
            log_message "Status file exists but not valid JSON" "warn"
        fi
    else
        log_message "Status file exists but empty" "warn"
    fi
fi

# If we get here, either no file exists or it's invalid/old
# Check if track file exists (as a fallback)
if [ -f "$TRACK_FILE" ]; then
    status_info=$(cat "$TRACK_FILE")
    status=$(echo "$status_info" | cut -d':' -f1)
    profile=$(echo "$status_info" | cut -d':' -f2)
    progress=$(echo "$status_info" | cut -d':' -f3)
    
    # Make sure the message reflects the actual status
    if [ "$status" = "success" ]; then
        message="Profile successfully applied"
    elif [ "$status" = "applying" ]; then
        message="Profile operation in progress"
    elif [ "$status" = "error" ]; then
        message="Profile operation failed"
    elif [ "$status" = "rebooting" ]; then
        message="Device is rebooting to apply changes"
    else
        message="Profile operation status: $status"
    fi
    
    # Output JSON based on track file
    cat <<EOF
{
    "status": "$status",
    "message": "$message",
    "profile": "$profile",
    "progress": $progress,
    "timestamp": $(date +%s)
}
EOF
    log_message "Retrieved status from track file: $status" "info"
    exit 0
fi

# If no valid files found, output idle state
output_idle_json