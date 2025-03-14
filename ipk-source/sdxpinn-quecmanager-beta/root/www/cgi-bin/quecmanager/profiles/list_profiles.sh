#!/bin/sh
# Location: /www/cgi-bin/quecmanager/profiles/list_profiles.sh

# Set content type to JSON and ensure blank line is output
echo "Content-type: application/json"
echo ""

# Function to log messages
log_message() {
    local level="${2:-info}"
    logger -t quecprofiles -p "daemon.$level" "list_profiles: $1"
    # Also log to our error file
    echo "[$(date)] $level: $1" >>/tmp/list_profiles_error.log
}

# Function to output JSON error response
output_error() {
    local message="$1"
    echo "{\"status\":\"error\",\"message\":\"$message\",\"profiles\":[]}"
    log_message "$message" "error"
    exit 1
}

# Function to sanitize string for JSON
sanitize_for_json() {
    echo "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/\t/\\t/g' | tr -d '\r\n'
}

# Check if UCI command exists
if ! which uci >/dev/null 2>&1; then
    output_error "UCI command not found"
fi

# Function to extract profiles from UCI config
get_profiles() {
    log_message "Fetching profiles from UCI config"
    
    # Check if UCI config exists
    if [ ! -f /etc/config/quecprofiles ]; then
        log_message "No profiles config found" "warn"
        echo "{\"status\":\"success\",\"profiles\":[]}"
        return 0
    fi
    
    # Start JSON output
    local json_output=""
    local first=1
    local count=0
    
    # Get all profile indices - make sure this succeeds
    local indices=$(uci -q show quecprofiles | grep -o '@profile\[[0-9]*\]' | sort -u)
    
    # Debug output
    echo "Found indices: $indices" >>/tmp/list_profiles_error.log
    
    if [ -z "$indices" ]; then
        log_message "No profile indices found" "warn"
        echo "{\"status\":\"success\",\"profiles\":[]}"
        return 0
    fi
    
    # Process each profile
    for idx in $indices; do
        log_message "Processing profile index: $idx"
        
        # Try different UCI get approaches
        local name
        name=$(uci -q get "quecprofiles.$idx.name" 2>/dev/null)
        if [ -z "$name" ]; then
            log_message "Failed to get name for $idx, trying alternative method" "warn"
            local section=${idx#@profile[}
            section=${section%]}
            name=$(uci -q get "quecprofiles.@profile[$section].name" 2>/dev/null)
        fi
        
        # Get profile details
        local iccid=$(uci -q get "quecprofiles.$idx.iccid" 2>/dev/null)
        local imei=$(uci -q get "quecprofiles.$idx.imei" 2>/dev/null)
        local apn=$(uci -q get "quecprofiles.$idx.apn" 2>/dev/null)
        local pdp_type=$(uci -q get "quecprofiles.$idx.pdp_type" 2>/dev/null)
        local lte_bands=$(uci -q get "quecprofiles.$idx.lte_bands" 2>/dev/null)
        local sa_nr5g_bands=$(uci -q get "quecprofiles.$idx.sa_nr5g_bands" 2>/dev/null)
        local nsa_nr5g_bands=$(uci -q get "quecprofiles.$idx.nsa_nr5g_bands" 2>/dev/null)
        local network_type=$(uci -q get "quecprofiles.$idx.network_type" 2>/dev/null)
        local ttl=$(uci -q get "quecprofiles.$idx.ttl" 2>/dev/null)
        
        # Debug output
        log_message "Retrieved for $idx: name=$name, iccid=$iccid, apn=$apn"

        # Skip if missing required fields
        if [ -z "$name" ] || [ -z "$iccid" ] || [ -z "$apn" ]; then
            log_message "Skipping invalid profile: $idx (missing required fields)" "warn"
            continue
        fi
        
        # Sanitize all values to ensure valid JSON
        name=$(sanitize_for_json "$name")
        iccid=$(sanitize_for_json "$iccid")
        imei=$(sanitize_for_json "${imei:-""}")
        apn=$(sanitize_for_json "$apn")
        pdp_type=$(sanitize_for_json "${pdp_type:-"IPV4V6"}")
        lte_bands=$(sanitize_for_json "${lte_bands:-""}")
        sa_nr5g_bands=$(sanitize_for_json "${sa_nr5g_bands:-""}")
        nsa_nr5g_bands=$(sanitize_for_json "${nsa_nr5g_bands:-""}")
        network_type=$(sanitize_for_json "${network_type:-"LTE"}")
        ttl=$(sanitize_for_json "${ttl:-0}")
        
        # Create profile JSON
        local profile_json="{"
        profile_json="${profile_json}\"name\":\"${name}\","
        profile_json="${profile_json}\"iccid\":\"${iccid}\","
        profile_json="${profile_json}\"imei\":\"${imei}\","
        profile_json="${profile_json}\"apn\":\"${apn}\","
        profile_json="${profile_json}\"pdp_type\":\"${pdp_type}\","
        profile_json="${profile_json}\"lte_bands\":\"${lte_bands}\","
        profile_json="${profile_json}\"sa_nr5g_bands\":\"${sa_nr5g_bands}\","
        profile_json="${profile_json}\"nsa_nr5g_bands\":\"${nsa_nr5g_bands}\","
        profile_json="${profile_json}\"network_type\":\"${network_type}\","
        profile_json="${profile_json}\"ttl\":\"${ttl}\""
        profile_json="${profile_json}}"
        
        # Add comma if not first
        if [ $first -eq 0 ]; then
            json_output="${json_output},"
        else
            first=0
        fi
        
        # Add profile to output
        json_output="${json_output}${profile_json}"
        count=$((count+1))
    done
    
    # Complete the JSON response
    local response="{\"status\":\"success\",\"profiles\":[${json_output}]}"
    
    # Save the response for debugging
    echo "$response" > /tmp/list_profiles_response.json
    
    echo "$response"
    log_message "Found and returned $count profiles"
    return 0
}

# Start fresh error log
echo "=== List Profiles Run $(date) ===" > /tmp/list_profiles_error.log

# Main execution
{
    get_profiles
} || {
    # Error handler
    output_error "Failed to retrieve profiles"
}