#!/bin/sh
# Location: /www/cgi-bin/quecmanager/profiles/quec_profile_edit.sh

# Set content type to JSON
echo -n ""
echo "Content-type: application/json"
echo ""

# Configuration
CHECK_TRIGGER="/tmp/quecprofiles_check"
APPLIED_FLAG="/tmp/quecprofiles_applied"

# Function to log messages
log_message() {
    local level="${2:-info}"
    logger -t quecprofiles -p "daemon.$level" "edit: $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] edit: $1" >>/tmp/quec_profile_edit.log
}

# Function to output JSON response
output_json() {
    local status="$1"
    local message="$2"
    local data="${3:-{}}"

    # Debug log to file only
    echo "Generating JSON response: status=$status, message=$message" >>/tmp/quec_profile_debug.log
    echo "Data payload: $data" >>/tmp/quec_profile_debug.log

    # Use printf for consistent output without newlines or extra characters
    printf '{"status":"%s","message":"%s","data":%s}' "$status" "$message" "$data"

    # Add debug marker at end of JSON
    echo "" >>/tmp/quec_profile_debug.log
    echo "JSON response generated at $(date)" >>/tmp/quec_profile_debug.log

    exit 0
}

# Function to sanitize input
sanitize() {
    echo "$1" | tr -d '\r\n' | sed 's/[^a-zA-Z0-9,.:_-]//g'
}

# Function to validate ICCID (simple check)
validate_iccid() {
    local iccid="$1"
    if [ -z "$iccid" ] || [ ${#iccid} -lt 10 ] || [ ${#iccid} -gt 20 ]; then
        return 1
    fi
    # Check that it's only digits
    if ! echo "$iccid" | grep -q '^[0-9]\+$'; then
        return 1
    fi
    return 0
}

# Function to validate IMEI (simple check)
validate_imei() {
    local imei="$1"
    if [ -z "$imei" ]; then
        return 0 # IMEI is optional
    fi
    if [ ${#imei} -ne 15 ] || ! echo "$imei" | grep -q '^[0-9]\+$'; then
        return 1
    fi
    return 0
}

# Function to validate band list
validate_bands() {
    local bands="$1"
    if [ -z "$bands" ]; then
        return 0 # Empty is valid
    fi
    # Check format (comma-separated numbers)
    if ! echo "$bands" | grep -q '^[0-9]\+\(,[0-9]\+\)*$'; then
        return 1
    fi
    return 0
}

# Function to validate network type
validate_network_type() {
    local net_type="$1"
    case "$net_type" in
    "LTE" | "NR5G" | "LTE:NR5G")
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

# Function to validate PDP type
validate_pdp_type() {
    local pdp_type="$1"
    case "$pdp_type" in
    "IP" | "IPV6" | "IPV4V6")
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

validate_ttl() {
    local ttl="$1"
    if [ -z "$ttl" ]; then
        return 0 # Empty is valid (will be treated as 0/disabled)
    fi
    # Check that TTL is a number between 0 and 255
    if ! echo "$ttl" | grep -q '^[0-9]\+$' || [ "$ttl" -gt 255 ]; then
        return 1
    fi
    return 0
}

# Function to check if a profile with given ICCID exists
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

# Function to check for duplicate name (excluding current profile)
check_duplicate_name() {
    local name="$1"
    local current_iccid="$2"

    local profile_indices=$(uci show quecprofiles | grep -o '@profile\[[0-9]\+\]' | sort -u)

    for profile_index in $profile_indices; do
        local iccid=$(uci -q get quecprofiles.$profile_index.iccid)
        local profile_name=$(uci -q get quecprofiles.$profile_index.name)

        # Skip the current profile we're editing
        if [ "$iccid" = "$current_iccid" ]; then
            continue
        fi

        if [ "$profile_name" = "$name" ]; then
            return 0 # Found duplicate
        fi
    done

    return 1 # No duplicate
}

# Function to update an existing profile
update_profile() {
    local profile_index="$1"
    local name="$2"
    local imei="$3"
    local apn="$4"
    local pdp_type="$5"
    local lte_bands="$6"
    local sa_nr5g_bands="$7"
    local nsa_nr5g_bands="$8"
    local network_type="$9"
    local ttl="${10}"

    # Update the profile in UCI config
    uci -q batch <<EOF
set quecprofiles.$profile_index.name='$name'
set quecprofiles.$profile_index.imei='$imei'
set quecprofiles.$profile_index.apn='$apn'
set quecprofiles.$profile_index.pdp_type='$pdp_type'
set quecprofiles.$profile_index.lte_bands='$lte_bands'
set quecprofiles.$profile_index.sa_nr5g_bands='$sa_nr5g_bands'
set quecprofiles.$profile_index.nsa_nr5g_bands='$nsa_nr5g_bands'
set quecprofiles.$profile_index.network_type='$network_type'
set quecprofiles.$profile_index.ttl='$ttl'
commit quecprofiles
EOF

    # Check if the operation was successful
    if [ $? -eq 0 ]; then
        log_message "Successfully updated profile '$name'" "info"

        # Remove the applied flag file to force reapplication on next check
        rm -f "$APPLIED_FLAG"

        # Touch the check trigger file to force daemon to check ASAP
        touch "$CHECK_TRIGGER"

        log_message "Triggered profile check for updated profile '$name'" "info"
        return 0
    else
        log_message "Failed to update profile '$name'" "error"
        return 1
    fi
}

# Output debug info
log_message "Received edit profile request" "debug"

# Ensure UCI config exists
if [ ! -f /etc/config/quecprofiles ]; then
    log_message "quecprofiles config does not exist" "error"
    output_json "error" "Configuration file not found"
fi

# Get POST data
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
            name=$(echo "$POST_DATA" | jsonfilter -e '@.name' 2>/dev/null)
            imei=$(echo "$POST_DATA" | jsonfilter -e '@.imei' 2>/dev/null)
            apn=$(echo "$POST_DATA" | jsonfilter -e '@.apn' 2>/dev/null)
            pdp_type=$(echo "$POST_DATA" | jsonfilter -e '@.pdp_type' 2>/dev/null)
            lte_bands=$(echo "$POST_DATA" | jsonfilter -e '@.lte_bands' 2>/dev/null)
            sa_nr5g_bands=$(echo "$POST_DATA" | jsonfilter -e '@.sa_nr5g_bands' 2>/dev/null)
            nsa_nr5g_bands=$(echo "$POST_DATA" | jsonfilter -e '@.nsa_nr5g_bands' 2>/dev/null)
            network_type=$(echo "$POST_DATA" | jsonfilter -e '@.network_type' 2>/dev/null)
            ttl=$(echo "$POST_DATA" | jsonfilter -e '@.ttl' 2>/dev/null)

            log_message "Parsed JSON data for profile: $name" "debug"
        else
            # If jsonfilter is not available, try basic parsing
            # This is less reliable but might work for simple cases
            iccid=$(echo "$POST_DATA" | grep -o '"iccid":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
            name=$(echo "$POST_DATA" | grep -o '"name":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
            imei=$(echo "$POST_DATA" | grep -o '"imei":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
            apn=$(echo "$POST_DATA" | grep -o '"apn":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
            pdp_type=$(echo "$POST_DATA" | grep -o '"pdp_type":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
            lte_bands=$(echo "$POST_DATA" | grep -o '"lte_bands":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
            sa_nr5g_bands=$(echo "$POST_DATA" | grep -o '"sa_nr5g_bands":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
            nsa_nr5g_bands=$(echo "$POST_DATA" | grep -o '"nsa_nr5g_bands":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
            network_type=$(echo "$POST_DATA" | grep -o '"network_type":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
            ttl=$(echo "$POST_DATA" | grep -o '"ttl":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')

            log_message "Basic parsing for profile: $name" "warn"
        fi
    else
        log_message "No content length specified" "error"
        output_json "error" "No data received"
    fi
else
    # URL parameters for GET requests (less secure, but supported for testing)
    iccid=$(echo "$QUERY_STRING" | grep -o 'iccid=[^&]*' | cut -d'=' -f2)
    name=$(echo "$QUERY_STRING" | grep -o 'name=[^&]*' | cut -d'=' -f2)
    imei=$(echo "$QUERY_STRING" | grep -o 'imei=[^&]*' | cut -d'=' -f2)
    apn=$(echo "$QUERY_STRING" | grep -o 'apn=[^&]*' | cut -d'=' -f2)
    pdp_type=$(echo "$QUERY_STRING" | grep -o 'pdp_type=[^&]*' | cut -d'=' -f2)
    lte_bands=$(echo "$QUERY_STRING" | grep -o 'lte_bands=[^&]*' | cut -d'=' -f2)
    sa_nr5g_bands=$(echo "$QUERY_STRING" | grep -o 'sa_nr5g_bands=[^&]*' | cut -d'=' -f2)
    nsa_nr5g_bands=$(echo "$QUERY_STRING" | grep -o 'nsa_nr5g_bands=[^&]*' | cut -d'=' -f2)
    network_type=$(echo "$QUERY_STRING" | grep -o 'network_type=[^&]*' | cut -d'=' -f2)
    ttl=$(echo "$QUERY_STRING" | grep -o 'ttl=[^&]*' | cut -d'=' -f2)

    # URL decode values
    iccid=$(echo "$iccid" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
    name=$(echo "$name" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
    imei=$(echo "$imei" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
    apn=$(echo "$apn" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
    pdp_type=$(echo "$pdp_type" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
    lte_bands=$(echo "$lte_bands" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
    sa_nr5g_bands=$(echo "$sa_nr5g_bands" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
    nsa_nr5g_bands=$(echo "$nsa_nr5g_bands" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
    network_type=$(echo "$network_type" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
    ttl=$(echo "$ttl" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")

    log_message "Using URL parameters" "warn"
fi

# Sanitize inputs
iccid=$(sanitize "${iccid:-}")
name=$(sanitize "${name:-}")
imei=$(sanitize "${imei:-}")
apn=$(sanitize "${apn:-}")
pdp_type=$(sanitize "${pdp_type:-IP}")
lte_bands=$(sanitize "${lte_bands:-}")
sa_nr5g_bands=$(sanitize "${sa_nr5g_bands:-}")
nsa_nr5g_bands=$(sanitize "${nsa_nr5g_bands:-}")
network_type=$(sanitize "${network_type:-LTE}")
ttl=$(sanitize "${ttl:-0}") # Default to 0 (disabled)

# Output debug info
log_message "Editing profile: $name, ICCID: $iccid, IMEI: $imei, APN: $apn" "debug"

# Validate required inputs
if [ -z "$iccid" ]; then
    log_message "ICCID is missing" "error"
    output_json "error" "ICCID is required to identify the profile"
fi

if [ -z "$name" ]; then
    log_message "Profile name is missing" "error"
    output_json "error" "Profile name is required"
fi

if [ -z "$apn" ]; then
    log_message "APN is missing" "error"
    output_json "error" "APN is required"
fi

# Validate input formats
if ! validate_iccid "$iccid"; then
    log_message "Invalid ICCID format: $iccid" "error"
    output_json "error" "Invalid ICCID format. It should be 10-20 digits."
fi

if ! validate_imei "$imei"; then
    log_message "Invalid IMEI format: $imei" "error"
    output_json "error" "Invalid IMEI format. It should be exactly 15 digits."
fi

if ! validate_bands "$lte_bands"; then
    log_message "Invalid LTE bands format: $lte_bands" "error"
    output_json "error" "Invalid LTE bands format. Use comma-separated numbers (e.g., 1,3,7)"
fi

if ! validate_bands "$sa_nr5g_bands"; then
    log_message "Invalid SA NR5G bands format: $sa_nr5g_bands" "error"
    output_json "error" "Invalid SA NR5G bands format. Use comma-separated numbers (e.g., 41,78)"
fi

if ! validate_bands "$nsa_nr5g_bands"; then
    log_message "Invalid NSA NR5G bands format: $nsa_nr5g_bands" "error"
    output_json "error" "Invalid NSA NR5G bands format. Use comma-separated numbers (e.g., 1,79)"
fi

if ! validate_network_type "$network_type"; then
    log_message "Invalid network type: $network_type" "error"
    output_json "error" "Invalid network type. Use 'LTE', 'NR5G', or 'LTE:NR5G'"
fi

if ! validate_pdp_type "$pdp_type"; then
    log_message "Invalid PDP type: $pdp_type" "error"
    output_json "error" "Invalid PDP type. Use 'IP', 'IPV6', or 'IPV4V6'"
fi

if ! validate_ttl "$ttl"; then
    log_message "Invalid TTL value: $ttl" "error"
    output_json "error" "Invalid TTL value. It should be a number between 0 and 255."
fi

# Find profile to edit
profile_index=$(find_profile_by_iccid "$iccid")
if [ $? -ne 0 ]; then
    log_message "Profile with ICCID $iccid not found" "error"
    output_json "error" "Profile not found"
fi

# Check for duplicate name
if check_duplicate_name "$name" "$iccid"; then
    log_message "Duplicate profile name: $name" "error"
    output_json "error" "A profile with this name already exists"
fi

# Update profile
if update_profile "$profile_index" "$name" "$imei" "$apn" "$pdp_type" "$lte_bands" "$nr5g_bands" "$network_type"; then
    # Trigger immediate profile application
    touch "/tmp/quecprofiles_check"
    chmod 644 "/tmp/quecprofiles_check"
    log_message "Triggered immediate profile check after update" "info"
    
    # Create a clean JSON response with properly escaped quotes
    printf '{"status":"success","message":"Profile updated successfully","data":{"name":"%s","iccid":"%s","imei":"%s","apn":"%s","pdp_type":"%s","lte_bands":"%s","nr5g_bands":"%s","network_type":"%s"}}' \
        "$name" "$iccid" "$imei" "$apn" "$pdp_type" "$lte_bands" "$nr5g_bands" "$network_type"
    
    log_message "Profile updated successfully: $name" "info"
    
    # Note: The conditional trigger is replaced with the direct trigger above
else
    printf '{"status":"error","message":"Failed to update profile. Please check system logs."}'
    log_message "Failed to update profile: $name" "error"
fi