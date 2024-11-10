#!/bin/sh

echo "Content-type: application/json"
echo ""

# Initialize error flag
has_error=false
error_message=""

# Function to append to error message
append_error() {
    if [ -z "$error_message" ]; then
        error_message="$1"
    else
        error_message="$error_message; $1"
    fi
    has_error=true
}

# Remove the entire quecmanager directory
if [ -d "/etc/quecmanager" ]; then
    rm -rf /etc/quecmanager
    if [ $? -ne 0 ]; then
        append_error "Failed to remove quecmanager directory"
    fi
else
    append_error "quecmanager directory not found"
fi

# Remove the line from rc.local
if [ -f "/etc/rc.local" ]; then
    # Create a temporary file
    temp_file=$(mktemp)
    
    # Remove the apnProfiles.sh line and copy to temp file
    sed '/\/etc\/quecmanager\/apnProfiles.sh/d' /etc/rc.local > "$temp_file"
    
    # Check if sed command was successful
    if [ $? -eq 0 ]; then
        # Replace original file with modified version
        mv "$temp_file" /etc/rc.local
        if [ $? -ne 0 ]; then
            append_error "Failed to update rc.local"
        fi
    else
        append_error "Failed to modify rc.local"
        rm -f "$temp_file"
    fi
else
    append_error "rc.local file not found"
fi

# Remove temporary files that might have been created
rm -f /tmp/apn_result.txt
rm -f /tmp/debug.log
rm -f /tmp/inputICCID.txt
rm -f /tmp/outputICCID.txt
rm -f /tmp/inputAPN.txt
rm -f /tmp/outputAPN.txt

# Return appropriate JSON response
if [ "$has_error" = true ]; then
    echo "{\"status\": \"error\", \"message\": \"$error_message\"}"
else
    echo "{\"status\": \"success\", \"message\": \"APN profiles and configuration successfully removed\"}"
fi