#!/bin/sh
# Location: /www/cgi-bin/quecmanager/profiles/quec_profile_create.sh

# Set content type to JSON
echo -n ""
echo "Content-type: application/json"
echo ""

# Function to log messages
log_message() {
    local level="${2:-info}"
    logger -t quecprofiles -p "daemon.$level" "create: $1"
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

# Add function to validate TTL
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

# Function to check if a profile with the same name or ICCID already exists
check_duplicate_profile() {
    local name="$1"
    local iccid="$2"

    # Check for duplicate name
    local existing_name=$(uci -q show quecprofiles | grep ".name='$name'" | head -n 1)
    if [ -n "$existing_name" ]; then
        return 1
    fi

    # Check for duplicate ICCID
    local existing_iccid=$(uci -q show quecprofiles | grep ".iccid='$iccid'" | head -n 1)
    if [ -n "$existing_iccid" ]; then
        return 2
    fi

    return 0
}

# Function to create new profile
create_profile() {
    local name="$1"
    local iccid="$2"
    local imei="$3"
    local apn="$4"
    local pdp_type="$5"
    local lte_bands="$6"
    local sa_nr5g_bands="$7"
    local nsa_nr5g_bands="$8"
    local network_type="$9"
    local ttl="${10}"

    # Generate a unique ID for the profile
    local profile_id="profile_$(date +%s)_$(head -c 4 /dev/urandom | hexdump -e '"%x"')"

    # Add to UCI config
    uci -q batch <<EOF
add quecprofiles profile
set quecprofiles.@profile[-1].name='$name'
set quecprofiles.@profile[-1].iccid='$iccid'
set quecprofiles.@profile[-1].imei='$imei'
set quecprofiles.@profile[-1].apn='$apn'
set quecprofiles.@profile[-1].pdp_type='$pdp_type'
set quecprofiles.@profile[-1].lte_bands='$lte_bands'
set quecprofiles.@profile[-1].sa_nr5g_bands='$sa_nr5g_bands'
set quecprofiles.@profile[-1].nsa_nr5g_bands='$nsa_nr5g_bands'
set quecprofiles.@profile[-1].network_type='$network_type'
set quecprofiles.@profile[-1].ttl='$ttl'
set quecprofiles.@profile[-1].paused='0'
commit quecprofiles
EOF

    # Check if the operation was successful
    if [ $? -eq 0 ]; then
        log_message "Successfully created profile '$name' for ICCID $iccid"
        return 0
    else
        log_message "Failed to create profile '$name'" "error"
        return 1
    fi
}

# Output debug info
log_message "Received create profile request" "debug"

# Ensure UCI config exists
if [ ! -f /etc/config/quecprofiles ]; then
    # Create initial config file
    cat >/etc/config/quecprofiles <<EOF
config quecprofiles 'settings'
    option check_interval '60'
    option enable_autoswitch '1'
    option apply_priority '20'
EOF
    log_message "Created initial quecprofiles config file"
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
            name=$(echo "$POST_DATA" | jsonfilter -e '@.name' 2>/dev/null)
            iccid=$(echo "$POST_DATA" | jsonfilter -e '@.iccid' 2>/dev/null)
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
            name=$(echo "$POST_DATA" | grep -o '"name":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
            iccid=$(echo "$POST_DATA" | grep -o '"iccid":"[^"]*"' | head -1 | cut -d':' -f2 | tr -d '"')
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
    name=$(echo "$QUERY_STRING" | grep -o 'name=[^&]*' | cut -d'=' -f2)
    iccid=$(echo "$QUERY_STRING" | grep -o 'iccid=[^&]*' | cut -d'=' -f2)
    imei=$(echo "$QUERY_STRING" | grep -o 'imei=[^&]*' | cut -d'=' -f2)
    apn=$(echo "$QUERY_STRING" | grep -o 'apn=[^&]*' | cut -d'=' -f2)
    pdp_type=$(echo "$QUERY_STRING" | grep -o 'pdp_type=[^&]*' | cut -d'=' -f2)
    lte_bands=$(echo "$QUERY_STRING" | grep -o 'lte_bands=[^&]*' | cut -d'=' -f2)
    sa_nr5g_bands=$(echo "$QUERY_STRING" | grep -o 'sa_nr5g_bands=[^&]*' | cut -d'=' -f2)
    nsa_nr5g_bands=$(echo "$QUERY_STRING" | grep -o 'nsa_nr5g_bands=[^&]*' | cut -d'=' -f2)
    network_type=$(echo "$QUERY_STRING" | grep -o 'network_type=[^&]*' | cut -d'=' -f2)
    ttl=$(echo "$QUERY_STRING" | grep -o 'ttl=[^&]*' | cut -d'=' -f2)

    # URL decode values
    name=$(echo "$name" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
    iccid=$(echo "$iccid" | sed 's/+/ /g;s/%\(..\)/\\x\1/g;' | xargs -0 printf "%b")
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
name=$(sanitize "${name:-}")
iccid=$(sanitize "${iccid:-}")
imei=$(sanitize "${imei:-}")
apn=$(sanitize "${apn:-}")
pdp_type=$(sanitize "${pdp_type:-IP}")
lte_bands=$(sanitize "${lte_bands:-}")
sa_nr5g_bands=$(sanitize "${sa_nr5g_bands:-}")
nsa_nr5g_bands=$(sanitize "${nsa_nr5g_bands:-}")
network_type=$(sanitize "${network_type:-LTE}")
ttl=$(sanitize "${ttl:-0}") # Default to 0 (disabled)

# Output debug info
log_message "Creating profile: $name, ICCID: $iccid, IMEI: $imei, APN: $apn" "debug"

# Validate required inputs
if [ -z "$name" ]; then
    log_message "Profile name is missing" "error"
    output_json "error" "Profile name is required"
fi

if [ -z "$iccid" ]; then
    log_message "ICCID is missing" "error"
    output_json "error" "ICCID is required"
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

# Check for duplicates
check_duplicate_profile "$name" "$iccid"
dup_status=$?
if [ $dup_status -eq 1 ]; then
    log_message "Duplicate profile name: $name" "error"
    output_json "error" "A profile with this name already exists"
elif [ $dup_status -eq 2 ]; then
    log_message "Duplicate ICCID: $iccid" "error"
    output_json "error" "A profile with this ICCID already exists"
fi

# Create the profile
if create_profile "$name" "$iccid" "$imei" "$apn" "$pdp_type" "$lte_bands" "$sa_nr5g_bands" "$nsa_nr5g_bands" "$network_type" "$ttl"; then
    # Trigger immediate profile application
    touch "/tmp/quecprofiles_check"
    chmod 644 "/tmp/quecprofiles_check"
    log_message "Triggered immediate profile check after creation" "info"
    
    # Create profile data JSON for return - WITHOUT outer curly braces
    profile_data="\"name\":\"$name\",\"iccid\":\"$iccid\",\"imei\":\"$imei\",\"apn\":\"$apn\",\"pdp_type\":\"$pdp_type\",\"lte_bands\":\"$lte_bands\",\"sa_nr5g_bands\":\"$sa_nr5g_bands\",\"nsa_nr5g_bands\":\"$nsa_nr5g_bands\",\"network_type\":\"$network_type\",\"ttl\":\"$ttl\""

    # Wrap the data field in curly braces inside output_json
    output_json "success" "Profile created successfully" "{$profile_data}"
else
    output_json "error" "Failed to create profile. Please check system logs."
fi