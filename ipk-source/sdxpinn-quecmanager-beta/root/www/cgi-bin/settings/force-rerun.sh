#!/bin/sh

# Send CGI headers first
echo "Content-Type: application/json"
echo "Cache-Control: no-cache"
echo

# Initialize variables for file paths
APN_SCRIPT="/etc/quecmanager/apn_profile/apnProfiles.sh"
IMEI_SCRIPT="/etc/quecmanager/imei_profile/imeiProfiles.sh"

# Function to output JSON
output_json() {
    local status="$1"
    local message="$2"
    echo "{\"status\": \"$status\", \"message\": \"$message\"}"
}

# Function to execute script if it exists
execute_if_exists() {
    local script_path="$1"
    
    if [ -f "$script_path" ] && [ -x "$script_path" ]; then
        $script_path >/dev/null 2>&1
        return $?
    fi
    return 2
}

# Main execution
main() {
    scripts_executed=0
    has_error=0
    
    # Try to execute APN script
    execute_if_exists "$APN_SCRIPT"
    apn_result=$?
    if [ $apn_result -eq 0 ]; then
        scripts_executed=$(($scripts_executed + 1))
    elif [ $apn_result -eq 1 ]; then
        has_error=1
    fi
    
    # Try to execute IMEI script
    execute_if_exists "$IMEI_SCRIPT"
    imei_result=$?
    if [ $imei_result -eq 0 ]; then
        scripts_executed=$(($scripts_executed + 1))
    elif [ $imei_result -eq 1 ]; then
        has_error=1
    fi
    
    # Output appropriate message based on results
    if [ $scripts_executed -eq 0 ]; then
        output_json "info" "No scripts to restart"
    elif [ $has_error -eq 1 ]; then
        output_json "error" "Error executing one or more scripts"
    else
        output_json "success" "Scripts restarted successfully"
    fi
}

# Run main function
main