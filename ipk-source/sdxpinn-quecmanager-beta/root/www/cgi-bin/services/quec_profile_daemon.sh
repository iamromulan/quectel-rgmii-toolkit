#!/bin/sh
# Updated QuecProfiles daemon with enhanced SA/NSA NR5G band management and TTL support
# Including profile application functions and fixed comparison logic

# Configuration
QUEUE_DIR="/tmp/at_queue"
TOKEN_FILE="$QUEUE_DIR/token"
TRACK_FILE="/tmp/quecprofiles_active"
CHECK_TRIGGER="/tmp/quecprofiles_check"
STATUS_FILE="/tmp/quecprofiles_status.json"
APPLIED_FLAG="/tmp/quecprofiles_applied"
DEBUG_LOG="/tmp/quecprofiles_debug.log"
DETAILED_LOG="/tmp/quecprofiles_detailed.log"
DEFAULT_CHECK_INTERVAL=60 # Default check interval in seconds
COMMAND_TIMEOUT=10        # Default timeout for AT commands in seconds
QUEUE_PRIORITY=3          # Medium-high priority (1 is highest for cell scan)
MAX_TOKEN_WAIT=15         # Maximum seconds to wait for token acquisition

# Initialize log file
echo "$(date) - Starting QuecProfiles daemon with SA/NSA NR5G and TTL support (PID: $$)" >"$DEBUG_LOG"
echo "$(date) - Starting QuecProfiles daemon with SA/NSA NR5G and TTL support (PID: $$)" >"$DETAILED_LOG"
chmod 644 "$DEBUG_LOG" "$DETAILED_LOG"

# Function to log messages
log_message() {
    local message="$1"
    local level="${2:-info}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # Log to system log
    logger -t quecprofiles_daemon -p "daemon.$level" "$message"

    # Log to debug file
    echo "[$timestamp] [$level] $message" >>"$DEBUG_LOG"

    # For detailed logs or errors
    if [ "$level" = "error" ] || [ "$level" = "debug" ]; then
        echo "[$timestamp] [$level] $message" >>"$DETAILED_LOG"
    fi
}

# Function to update track file with status - IMPROVED VERSION
update_track() {
    local status="$1"
    local message="$2"
    local profile="${3:-unknown}"
    local progress="${4:-0}"

    # Create JSON status
    cat >"$STATUS_FILE" <<EOF
{
    "status": "$status",
    "message": "$message",
    "profile": "$profile",
    "progress": $progress,
    "timestamp": "$(date +%s)"
}
EOF

    # Create simple track file for easy checking
    if [ "$status" = "idle" ]; then
        rm -f "$TRACK_FILE"
    else
        echo "$status:$profile:$progress" >"$TRACK_FILE"
        chmod 644 "$TRACK_FILE"
    fi

    log_message "Status updated: $status - $message ($progress%)"
}

# Function to find profile by ICCID in UCI
find_profile_by_iccid() {
    local iccid="$1"
    local profile_indices

    log_message "Looking for profile with ICCID: $iccid" "info"

    # Get all profile indices
    profile_indices=$(uci show quecprofiles | grep -o '@profile\[[0-9]\+\]' | sort -u)

    # Exit early if no profiles found
    if [ -z "$profile_indices" ]; then
        log_message "No profiles configured in the system" "info"
        return 1
    fi

    for profile_index in $profile_indices; do
        local current_iccid=$(uci -q get quecprofiles.$profile_index.iccid)
        if [ "$current_iccid" = "$iccid" ]; then
            log_message "Found matching profile: $profile_index" "info"
            echo "$profile_index"
            return 0
        fi
    done

    log_message "No matching profile found for ICCID: $iccid" "info"
    return 1
}

# Function to normalize and compare values - handles format differences
compare_values() {
    local current="$1"
    local desired="$2"
    local type="$3"

    # Skip empty values
    if [ -z "$desired" ]; then
        log_message "Desired value for $type is empty, skipping comparison" "debug"
        return 1 # No change needed
    fi

    # Normalize values for comparison
    local norm_current
    local norm_desired

    # Different normalization based on type
    case "$type" in
    "apn")
        # APN comparison is case-insensitive
        norm_current=$(echo "$current" | tr '[:upper:]' '[:lower:]')
        norm_desired=$(echo "$desired" | tr '[:upper:]' '[:lower:]')
        ;;
    "mode")
        # Network mode - normalize format and sort parts
        norm_current=$(echo "$current" | tr '[:upper:]' '[:lower:]' | tr ':' ',' | tr -d ' ' | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
        norm_desired=$(echo "$desired" | tr '[:upper:]' '[:lower:]' | tr ':' ',' | tr -d ' ' | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
        ;;
    "bands")
        # Bands - sort numbers for consistent comparison
        norm_current=$(echo "$current" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//')
        norm_desired=$(echo "$desired" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//')
        ;;
    *)
        # Default comparison
        norm_current="$current"
        norm_desired="$desired"
        ;;
    esac

    log_message "Comparing $type - Current: '$norm_current', Desired: '$norm_desired'" "debug"

    # Check if values are equivalent after normalization
    if [ "$norm_current" = "$norm_desired" ]; then
        log_message "$type values match after normalization" "debug"
        return 1 # No change needed
    else
        log_message "$type values differ after normalization - change needed" "debug"
        return 0 # Change needed
    fi
}

# Function to check if profile is already applied
is_profile_applied() {
    local iccid="$1"
    local profile_name="$2"

    # Check if applied flag exists and matches current profile
    if [ -f "$APPLIED_FLAG" ]; then
        local applied_data=$(cat "$APPLIED_FLAG" 2>/dev/null)
        local applied_iccid=$(echo "$applied_data" | cut -d':' -f1)
        local applied_name=$(echo "$applied_data" | cut -d':' -f2)
        local applied_time=$(echo "$applied_data" | cut -d':' -f3)

        # Check if the applied profile matches current one
        if [ "$applied_iccid" = "$iccid" ] && [ "$applied_name" = "$profile_name" ]; then
            log_message "Profile '$profile_name' already applied at $(date -d @$applied_time)" "info"
            return 0 # Profile already applied
        fi
    fi

    # No matching applied profile found
    return 1
}

# Function to mark profile as applied
mark_profile_applied() {
    local iccid="$1"
    local profile_name="$2"

    # Save profile application data
    echo "$iccid:$profile_name:$(date +%s)" >"$APPLIED_FLAG"
    chmod 644 "$APPLIED_FLAG"
    log_message "Marked profile '$profile_name' as applied for ICCID $iccid" "info"
}

# Enhanced JSON string escaping function
escape_json() {
    printf '%s' "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | tr -d '\n' | sed 's/\r//g'
}

# Function to acquire token directly with retries
acquire_token() {
    local lock_id="QUECPROFILES_$(date +%s)_$$"
    local priority="$QUEUE_PRIORITY"
    local max_attempts=$MAX_TOKEN_WAIT
    local attempt=0

    log_message "Attempting to acquire AT queue token with priority $priority" "debug"

    while [ $attempt -lt $max_attempts ]; do
        # Check if token file exists
        if [ -f "$TOKEN_FILE" ]; then
            local current_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id' 2>/dev/null)
            local current_priority=$(cat "$TOKEN_FILE" | jsonfilter -e '@.priority' 2>/dev/null)
            local timestamp=$(cat "$TOKEN_FILE" | jsonfilter -e '@.timestamp' 2>/dev/null)
            local current_time=$(date +%s)

            # Check for expired token (> 30 seconds old)
            if [ $((current_time - timestamp)) -gt 30 ] || [ -z "$current_holder" ]; then
                # Remove expired token
                log_message "Found expired token from $current_holder, removing" "debug"
                rm -f "$TOKEN_FILE" 2>/dev/null
            elif [ $priority -lt $current_priority ]; then
                # Preempt lower priority token
                log_message "Preempting token from $current_holder (priority: $current_priority)" "debug"
                rm -f "$TOKEN_FILE" 2>/dev/null
            else
                # Try again - higher priority token exists
                log_message "Token held by $current_holder with priority $current_priority, retrying..." "debug"
                sleep 0.5
                attempt=$((attempt + 1))
                continue
            fi
        fi

        # Try to create token file
        echo "{\"id\":\"$lock_id\",\"priority\":$priority,\"timestamp\":$(date +%s)}" >"$TOKEN_FILE" 2>/dev/null
        chmod 644 "$TOKEN_FILE" 2>/dev/null

        # Verify we got the token
        local holder=$(cat "$TOKEN_FILE" 2>/dev/null | jsonfilter -e '@.id' 2>/dev/null)
        if [ "$holder" = "$lock_id" ]; then
            log_message "Successfully acquired token with ID $lock_id" "debug"
            echo "$lock_id"
            return 0
        fi

        sleep 0.5
        attempt=$((attempt + 1))
    done

    log_message "Failed to acquire token after $max_attempts attempts" "error"
    return 1
}

# Function to release token
release_token() {
    local lock_id="$1"

    if [ -f "$TOKEN_FILE" ]; then
        local current_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id' 2>/dev/null)
        if [ "$current_holder" = "$lock_id" ]; then
            rm -f "$TOKEN_FILE" 2>/dev/null
            log_message "Released token $lock_id" "debug"
            return 0
        fi
        log_message "Token held by $current_holder, not by us ($lock_id)" "warn"
    else
        log_message "Token file doesn't exist, nothing to release" "debug"
    fi
    return 1
}

# Function to execute AT command with proper error handling
execute_at_command() {
    local cmd="$1"
    local timeout="${2:-$COMMAND_TIMEOUT}"
    local token_id="$3"

    if [ -z "$token_id" ]; then
        log_message "No valid token provided for command: $cmd" "error"
        return 1
    fi

    log_message "Executing AT command: $cmd (timeout: ${timeout}s)" "debug"

    # Execute the command with proper timeout
    local output=""
    local status=1

    # Check if sms_tool exists
    if which sms_tool >/dev/null 2>&1; then
        output=$(sms_tool at "$cmd" -t "$timeout" 2>&1)
        status=$?
        log_message "AT command executed, status: $status" "debug"
    else
        log_message "sms_tool not found, cannot execute AT command" "error"
        return 1
    fi

    # Log command output for debugging
    echo "Command: $cmd" >>"$DETAILED_LOG"
    echo "Output: $output" >>"$DETAILED_LOG"
    echo "Status: $status" >>"$DETAILED_LOG"

    if [ $status -ne 0 ]; then
        log_message "AT command failed: $cmd (exit code: $status)" "error"
        return 1
    fi

    echo "$output"
    return 0
}

# Function to fetch all modem data at once with a single token
fetch_modem_data() {
    local token_id=""
    local result=1
    local modem_data=""

    log_message "Fetching all modem data at once" "info"

    # Define commands to execute
    local COMMANDS="AT+ICCID AT+CGDCONT? AT+QNWPREFCFG=\"mode_pref\" AT+QNWPREFCFG=\"lte_band\" AT+QNWPREFCFG=\"nsa_nr5g_band\" AT+QNWPREFCFG=\"nr5g_band\" AT+CGSN"

    # Get token
    token_id=$(acquire_token)
    if [ -z "$token_id" ]; then
        log_message "Failed to acquire token for fetching modem data" "error"
        return 1
    fi

    # Execute each command and combine outputs
    for cmd in $COMMANDS; do
        log_message "Executing command: $cmd" "debug"
        local output=$(execute_at_command "$cmd" 5 "$token_id")
        local status=$?

        if [ $status -eq 0 ]; then
            # Append to modem_data
            modem_data="${modem_data}====COMMAND_START:${cmd}====\n${output}\n====COMMAND_END====\n\n"
        else
            log_message "Command failed: $cmd" "warn"
        fi
    done

    # Release token
    release_token "$token_id"

    if [ -n "$modem_data" ]; then
        # Save output to DETAILED_LOG for debugging
        echo -e "MODEM DATA:\n$modem_data" >>"$DETAILED_LOG"
        echo "$modem_data"
        return 0
    else
        log_message "No modem data fetched" "error"
        return 1
    fi
}

# Function to extract ICCID from modem data
extract_iccid() {
    local modem_data="$1"
    local iccid=""

    # Extract section containing ICCID command response
    local iccid_section=$(echo -e "$modem_data" | sed -n '/====COMMAND_START:AT+ICCID====/,/====COMMAND_END====/p')

    # Try to extract ICCID (look for 10-20 digit number)
    iccid=$(echo "$iccid_section" | grep -o '[0-9]\{10,20\}' | head -n 1)

    if [ -z "$iccid" ]; then
        log_message "Failed to extract ICCID from modem data" "error"
        return 1
    fi

    log_message "Extracted ICCID: $iccid" "info"
    echo "$iccid"
    return 0
}

# Function to extract APN from modem data
extract_apn() {
    local modem_data="$1"
    local apn=""

    # Extract section containing CGDCONT command response
    local apn_section=$(echo -e "$modem_data" | sed -n '/====COMMAND_START:AT+CGDCONT?====/,/====COMMAND_END====/p')

    # Try to extract APN from the response - look for context 1
    apn=$(echo "$apn_section" | grep -o '+CGDCONT: 1,[^,]*,"[^"]*"' | cut -d'"' -f2)

    if [ -z "$apn" ]; then
        # Try alternative pattern
        apn=$(echo "$apn_section" | grep -o '+CGDCONT: 1,[^,]*,[^,]*' | cut -d',' -f3 | tr -d '"')

        if [ -z "$apn" ]; then
            log_message "Failed to extract APN from modem data" "error"
            return 1
        fi
    fi

    log_message "Extracted APN: $apn" "info"
    echo "$apn"
    return 0
}

# Function to extract network mode from modem data
extract_network_mode() {
    local modem_data="$1"
    local mode=""

    # Extract section containing mode_pref command response
    local mode_section=$(echo -e "$modem_data" | sed -n '/====COMMAND_START:AT+QNWPREFCFG="mode_pref"====/,/====COMMAND_END====/p')

    # Try to extract mode from the response
    mode=$(echo "$mode_section" | grep -o '+QNWPREFCFG:.*' | cut -d'"' -f3)

    if [ -z "$mode" ]; then
        log_message "Failed to extract network mode from modem data" "error"
        return 1
    fi

    # Clean up the value - remove leading comma if present
    mode=$(echo "$mode" | sed 's/^,//')

    log_message "Extracted network mode: $mode" "info"
    echo "$mode"
    return 0
}

# Function to extract LTE bands from modem data
extract_lte_bands() {
    local modem_data="$1"
    local bands=""

    # Extract section containing lte_band command response
    local bands_section=$(echo -e "$modem_data" | sed -n '/====COMMAND_START:AT+QNWPREFCFG="lte_band"====/,/====COMMAND_END====/p')

    # Try to extract bands from the response
    bands=$(echo "$bands_section" | grep -o '+QNWPREFCFG:.*' | cut -d'"' -f3)

    if [ -z "$bands" ]; then
        log_message "Failed to extract LTE bands from modem data" "error"
        return 1
    fi

    # Convert colon-separated to comma-separated and remove leading comma if present
    bands=$(echo "$bands" | tr ':' ',' | sed 's/^,//')

    log_message "Extracted LTE bands: $bands" "info"
    echo "$bands"
    return 0
}

# Updated: Function to extract both SA and NSA NR5G bands from modem data
extract_nr5g_bands() {
    local modem_data="$1"
    local bands_type="$2" # "sa" or "nsa"

    local section_type=""
    if [ "$bands_type" = "sa" ]; then
        section_type="nr5g_band"
    else
        section_type="nsa_nr5g_band"
    fi

    # Extract sections containing NR5G band command responses
    local bands_section=$(echo -e "$modem_data" | sed -n "/====COMMAND_START:AT+QNWPREFCFG=\"$section_type\"====/,/====COMMAND_END====/p")

    # Try to extract bands
    local bands=$(echo "$bands_section" | grep -o '+QNWPREFCFG:.*' | cut -d'"' -f3)

    if [ -n "$bands" ]; then
        # Clean up the value - convert colon-separated to comma-separated and remove leading comma
        bands=$(echo "$bands" | tr ':' ',' | sed 's/^,//')
        log_message "Extracted $bands_type NR5G bands: $bands" "info"
        echo "$bands"
        return 0
    fi

    log_message "Failed to extract $bands_type NR5G bands from modem data" "warn"
    return 1
}

# Function to extract IMEI from modem data
extract_imei() {
    local modem_data="$1"
    local imei=""

    # Extract section containing CGSN command response
    local imei_section=$(echo -e "$modem_data" | sed -n '/====COMMAND_START:AT+CGSN====/,/====COMMAND_END====/p')

    # Try to extract IMEI (look for 15 digit number)
    imei=$(echo "$imei_section" | grep -o '[0-9]\{15\}' | head -n 1)

    if [ -z "$imei" ]; then
        log_message "Failed to extract IMEI from modem data" "error"
        return 1
    fi

    log_message "Extracted IMEI: $imei" "info"
    echo "$imei"
    return 0
}

# Function to setup TTL configuration persistence
setup_ttl_persistence() {
    if [ ! -f "/etc/data/lanUtils.sh" ]; then
        log_message "lanUtils.sh not found, TTL changes might not persist across reboots" "warn"
        return 1
    fi

    # Backup the original script if not already done
    if [ ! -f "/etc/data/lanUtils.sh.bak" ]; then
        cp "/etc/data/lanUtils.sh" "/etc/data/lanUtils.sh.bak"
    fi

    # Add the local ttl_firewall_file line if it's not already present
    if ! grep -q "local ttl_firewall_file" "/etc/data/lanUtils.sh"; then
        sed -i '/local tcpmss_firewall_filev6/a \  local ttl_firewall_file=/etc/firewall.user.ttl' "/etc/data/lanUtils.sh"
    fi

    # Add the condition to include the ttl_firewall_file if it's not already present
    if ! grep -q "if \[ -f \"\$ttl_firewall_file\" \]; then" "/etc/data/lanUtils.sh"; then
        sed -i '/if \[ -f "\$tcpmss_firewall_filev6" \]; then/i \  if [ -f "\$ttl_firewall_file" ]; then\n    cat \$ttl_firewall_file >> \$firewall_file\n  fi' "/etc/data/lanUtils.sh"
    fi

    log_message "TTL persistence setup completed" "info"
    return 0
}

# Function to apply TTL settings
apply_ttl_settings() {
    local ttl="$1"
    local current_ttl="$2"
    local token_id="$3"
    local profile_name="$4"

    # If TTL is not set, default to 0 (disabled)
    ttl="${ttl:-0}"
    current_ttl="${current_ttl:-0}"

    # Check if change is needed
    if [ "$ttl" = "$current_ttl" ]; then
        log_message "TTL already set to $ttl, no change needed" "debug"
        return 0
    fi

    update_track "applying" "Setting TTL from '$current_ttl' to '$ttl'" "$profile_name" "85"
    log_message "Changing TTL from '$current_ttl' to '$ttl'" "info"

    # Create TTL file directory if it doesn't exist
    mkdir -p /etc

    if [ "$ttl" = "0" ]; then
        # Clear existing rules
        iptables -t mangle -D POSTROUTING -o rmnet+ -j TTL --ttl-set "$current_ttl" 2>/dev/null
        ip6tables -t mangle -D POSTROUTING -o rmnet+ -j HL --hl-set "$current_ttl" 2>/dev/null
        >"/etc/firewall.user.ttl"
        log_message "TTL settings cleared" "info"
    else
        # Clear existing rules
        if [ "$current_ttl" != "0" ]; then
            iptables -t mangle -D POSTROUTING -o rmnet+ -j TTL --ttl-set "$current_ttl" 2>/dev/null
            ip6tables -t mangle -D POSTROUTING -o rmnet+ -j HL --hl-set "$current_ttl" 2>/dev/null
        fi

        # Set new rules
        echo "iptables -t mangle -A POSTROUTING -o rmnet+ -j TTL --ttl-set $ttl" >"/etc/firewall.user.ttl"
        echo "ip6tables -t mangle -A POSTROUTING -o rmnet+ -j HL --hl-set $ttl" >>"/etc/firewall.user.ttl"

        # Apply the rules
        iptables -t mangle -A POSTROUTING -o rmnet+ -j TTL --ttl-set "$ttl"
        ip6tables -t mangle -A POSTROUTING -o rmnet+ -j HL --hl-set "$ttl"

        log_message "TTL changed successfully to $ttl" "info"
    fi

    # Setup persistence
    setup_ttl_persistence

    return 0
}

# Function to get current TTL value
get_current_ttl() {
    local current_ttl=0

    if [ -f "/etc/firewall.user.ttl" ]; then
        current_ttl=$(grep 'iptables -t mangle -A POSTROUTING' "/etc/firewall.user.ttl" | awk '{for(i=1;i<=NF;i++){if($i=="--ttl-set"){print $(i+1)}}}')
        if ! [[ "$current_ttl" =~ ^[0-9]+$ ]]; then
            current_ttl=0
        fi
    fi

    log_message "Current TTL value: $current_ttl" "debug"
    echo "$current_ttl"
    return 0
}

# Updated function to apply profile settings with separate SA/NSA NR5G bands and TTL support
apply_profile_settings() {
    local profile_name="$1"
    local network_type="$2"
    local lte_bands="$3"
    local sa_nr5g_bands="$4"
    local nsa_nr5g_bands="$5"
    local apn="$6"
    local pdp_type="$7"
    local imei="$8"
    local ttl="$9"
    local current_apn="${10}"
    local current_mode="${11}"
    local current_lte_bands="${12}"
    local current_sa_nr5g_bands="${13}"
    local current_nsa_nr5g_bands="${14}"
    local current_imei="${15}"
    local iccid="${16}"

    # Set TTL to 0 (disabled) if not specified
    ttl="${ttl:-0}"

    log_message "Applying profile '$profile_name' with settings:" "info"
    log_message "- Network type: $network_type" "info"
    log_message "- LTE bands: $lte_bands" "info"
    log_message "- SA NR5G bands: $sa_nr5g_bands" "info"
    log_message "- NSA NR5G bands: $nsa_nr5g_bands" "info"
    log_message "- APN: $apn ($pdp_type)" "info"
    log_message "- IMEI: $imei" "info"
    log_message "- TTL: $ttl" "info"

    # Check if any changes are needed using improved comparison
    local needs_apn_change=0
    local needs_mode_change=0
    local needs_lte_bands_change=0
    local needs_sa_nr5g_bands_change=0
    local needs_nsa_nr5g_bands_change=0
    local needs_imei_change=0
    local needs_ttl_change=0
    local changes_needed=0
    local requires_reboot=0

    # Use normalized comparison
    compare_values "$current_apn" "$apn" "apn" && needs_apn_change=1 && changes_needed=1
    compare_values "$current_mode" "$network_type" "mode" && needs_mode_change=1 && changes_needed=1
    compare_values "$current_lte_bands" "$lte_bands" "bands" && needs_lte_bands_change=1 && changes_needed=1
    compare_values "$current_sa_nr5g_bands" "$sa_nr5g_bands" "bands" && needs_sa_nr5g_bands_change=1 && changes_needed=1
    compare_values "$current_nsa_nr5g_bands" "$nsa_nr5g_bands" "bands" && needs_nsa_nr5g_bands_change=1 && changes_needed=1

    # Get current TTL value
    local current_ttl=$(get_current_ttl)

    # Compare TTL values
    if [ "$current_ttl" != "$ttl" ]; then
        needs_ttl_change=1
        changes_needed=1
    fi

    # IMEI is a special case - only change if explicitly specified
    if [ -n "$imei" ]; then
        compare_values "$current_imei" "$imei" "imei" && needs_imei_change=1 && changes_needed=1 && requires_reboot=1
    fi

    if [ $changes_needed -eq 0 ]; then
        log_message "No changes needed for profile '$profile_name', settings already correct" "info"
        mark_profile_applied "$iccid" "$profile_name"
        update_track "success" "Profile already correctly applied" "$profile_name" "100"
        return 0
    fi

    # Get token for applying settings
    local token_id=$(acquire_token)
    if [ -z "$token_id" ]; then
        log_message "Failed to acquire token for applying profile settings" "error"
        update_track "error" "Failed to acquire token" "$profile_name" "0"
        return 1
    fi

    local apply_success=1
    local changes_made=0

    # Apply APN change first (most important)
    if [ $needs_apn_change -eq 1 ]; then
        update_track "applying" "Setting APN from '$current_apn' to '$apn'" "$profile_name" "20"
        log_message "Changing APN from '$current_apn' to '$apn' ($pdp_type)" "info"

        # Set APN using AT command
        local apn_cmd="AT+CGDCONT=1,\"$pdp_type\",\"$apn\""
        local output=$(execute_at_command "$apn_cmd" 10 "$token_id")

        if [ $? -eq 0 ]; then
            changes_made=1
            log_message "APN changed successfully to $apn ($pdp_type)" "info"

            # Verify APN setting - fetch APN again to confirm
            local verify_output=$(execute_at_command "AT+CGDCONT?" 5 "$token_id")
            if echo "$verify_output" | grep -q "\"$apn\""; then
                log_message "APN change verified successfully" "info"
                update_track "applying" "APN set successfully" "$profile_name" "30"
            else
                log_message "APN change could not be verified, continuing anyway" "warn"
            fi
        else
            log_message "Failed to change APN to $apn" "error"
            update_track "error" "Failed to set APN" "$profile_name" "20"
            apply_success=0
        fi
    fi

    # Apply network mode change
    if [ $needs_mode_change -eq 1 ] && [ $apply_success -eq 1 ]; then
        update_track "applying" "Setting network mode from '$current_mode' to '$network_type'" "$profile_name" "40"
        log_message "Changing network mode from '$current_mode' to '$network_type'" "info"

        # Format network mode for AT command (may already be in correct format)
        local mode_cmd="AT+QNWPREFCFG=\"mode_pref\",$network_type"
        local output=$(execute_at_command "$mode_cmd" 10 "$token_id")

        if [ $? -eq 0 ]; then
            changes_made=1
            log_message "Network mode changed successfully to $network_type" "info"
            update_track "applying" "Network mode set successfully" "$profile_name" "50"

            # If mode includes NR5G, ensure it's enabled
            if echo "$network_type" | grep -q "NR5G"; then
                log_message "Ensuring NR5G is enabled" "debug"
                local nr5g_cmd="AT+QNWPREFCFG=\"nr5g_disable_mode\",0"
                execute_at_command "$nr5g_cmd" 5 "$token_id"
            fi
        else
            log_message "Failed to change network mode to $network_type" "error"
            update_track "applying" "Failed to set network mode, continuing" "$profile_name" "45"
        fi
    fi

    # Apply LTE bands change
    if [ $needs_lte_bands_change -eq 1 ] && [ $apply_success -eq 1 ] && [ -n "$lte_bands" ]; then
        update_track "applying" "Setting LTE bands from '$current_lte_bands' to '$lte_bands'" "$profile_name" "60"
        log_message "Changing LTE bands from '$current_lte_bands' to '$lte_bands'" "info"

        # Convert comma-separated to colon-separated for AT command
        local bands_formatted=$(echo "$lte_bands" | tr ',' ':')
        local bands_cmd="AT+QNWPREFCFG=\"lte_band\",$bands_formatted"
        local output=$(execute_at_command "$bands_cmd" 10 "$token_id")

        if [ $? -eq 0 ]; then
            changes_made=1
            log_message "LTE bands changed successfully to $lte_bands" "info"
            update_track "applying" "LTE bands set successfully" "$profile_name" "70"
        else
            log_message "Failed to change LTE bands to $lte_bands" "error"
            update_track "applying" "Failed to set LTE bands, continuing" "$profile_name" "65"
        fi
    fi

    # Apply NSA NR5G bands change
    if [ $needs_nsa_nr5g_bands_change -eq 1 ] && [ $apply_success -eq 1 ] && [ -n "$nsa_nr5g_bands" ]; then
        update_track "applying" "Setting NSA NR5G bands from '$current_nsa_nr5g_bands' to '$nsa_nr5g_bands'" "$profile_name" "75"
        log_message "Changing NSA NR5G bands from '$current_nsa_nr5g_bands' to '$nsa_nr5g_bands'" "info"

        # Convert comma-separated to colon-separated for AT command
        local bands_formatted=$(echo "$nsa_nr5g_bands" | tr ',' ':')
        local nsa_cmd="AT+QNWPREFCFG=\"nsa_nr5g_band\",$bands_formatted"
        local output=$(execute_at_command "$nsa_cmd" 10 "$token_id")

        if [ $? -eq 0 ]; then
            changes_made=1
            log_message "NSA NR5G bands changed successfully to $nsa_nr5g_bands" "info"
            update_track "applying" "NSA NR5G bands set successfully" "$profile_name" "80"
        else
            log_message "Failed to change NSA NR5G bands to $nsa_nr5g_bands" "error"
            update_track "applying" "Failed to set NSA NR5G bands, continuing" "$profile_name" "75"
        fi
    fi

    # Apply SA NR5G bands change
    if [ $needs_sa_nr5g_bands_change -eq 1 ] && [ $apply_success -eq 1 ] && [ -n "$sa_nr5g_bands" ]; then
        update_track "applying" "Setting SA NR5G bands from '$current_sa_nr5g_bands' to '$sa_nr5g_bands'" "$profile_name" "85"
        log_message "Changing SA NR5G bands from '$current_sa_nr5g_bands' to '$sa_nr5g_bands'" "info"

        # Convert comma-separated to colon-separated for AT command
        local bands_formatted=$(echo "$sa_nr5g_bands" | tr ',' ':')
        local sa_cmd="AT+QNWPREFCFG=\"nr5g_band\",$bands_formatted"
        local output=$(execute_at_command "$sa_cmd" 10 "$token_id")

        if [ $? -eq 0 ]; then
            changes_made=1
            log_message "SA NR5G bands changed successfully to $sa_nr5g_bands" "info"
            update_track "applying" "SA NR5G bands set successfully" "$profile_name" "90"
        else
            log_message "Failed to change SA NR5G bands to $sa_nr5g_bands" "error"
            update_track "applying" "Failed to set SA NR5G bands, continuing" "$profile_name" "85"
        fi
    fi

    # Apply TTL change if needed
    if [ $needs_ttl_change -eq 1 ] && [ $apply_success -eq 1 ]; then
        apply_ttl_settings "$ttl" "$current_ttl" "$token_id" "$profile_name"
        if [ $? -eq 0 ]; then
            changes_made=1
            log_message "TTL settings applied successfully" "info"
        fi
    fi

    # Apply IMEI change (requires reboot)
    if [ $needs_imei_change -eq 1 ] && [ $apply_success -eq 1 ] && [ -n "$imei" ]; then
        update_track "applying" "Setting IMEI from '$current_imei' to '$imei'" "$profile_name" "95"
        log_message "Changing IMEI from '$current_imei' to '$imei'" "info"

        local imei_cmd="AT+EGMR=1,7,\"$imei\""
        local output=$(execute_at_command "$imei_cmd" 10 "$token_id")

        if [ $? -eq 0 ]; then
            changes_made=1
            requires_reboot=1
            log_message "IMEI changed successfully to $imei (device will reboot)" "info"
            update_track "rebooting" "IMEI changed, device will reboot" "$profile_name" "95"
        else
            log_message "Failed to change IMEI to $imei" "error"
            update_track "applying" "Failed to set IMEI, continuing" "$profile_name" "90"
            requires_reboot=0
        fi
    fi

    # Release token
    release_token "$token_id"

    # Mark profile as applied if changes were made
    if [ $changes_made -eq 1 ]; then
        mark_profile_applied "$iccid" "$profile_name"
    fi

    # If IMEI was changed, need to reboot
    if [ $requires_reboot -eq 1 ]; then
        log_message "IMEI change requires reboot, scheduling reboot..." "info"
        update_track "rebooting" "Device is rebooting to apply IMEI change" "$profile_name" "100"
        sleep 2
        reboot &
        return 0
    fi

    # Force network reset if changes were made but no reboot required
    if [ $changes_made -eq 1 ] && [ $requires_reboot -eq 0 ]; then
        log_message "Changes applied, resetting network connection to apply changes" "info"
        update_track "applying" "Resetting network connection" "$profile_name" "95"

        # Get a new token for network reset
        token_id=$(acquire_token)
        if [ -n "$token_id" ]; then
            # Force PDP context reconnection - note: errors here are common and non-fatal
            log_message "Forcing network reconnection" "info"
            execute_at_command "AT+COPS=2" 5 "$token_id" || true
            sleep 2
            execute_at_command "AT+COPS=0" 5 "$token_id" || true
            sleep 1

            # Release token
            release_token "$token_id"
        fi
    fi

    # Check if any changes were made
    if [ $changes_made -eq 0 ]; then
        log_message "Profile '$profile_name' already applied correctly, no changes needed" "info"
        update_track "success" "Profile already correctly applied" "$profile_name" "100"
    else
        log_message "Successfully applied profile '$profile_name'" "info"
        update_track "success" "Profile applied successfully" "$profile_name" "100"
    fi

    return 0
}

# Check profile function with updated SA/NSA bands and TTL support
check_profile() {
    local forced="${1:-0}"

    log_message "Performing profile check (forced=$forced)" "info"

    # Get all modem data at once with a single token
    local modem_data=""
    modem_data=$(fetch_modem_data)
    if [ $? -ne 0 ]; then
        log_message "Failed to fetch modem data, will retry later" "error"
        update_track "error" "Could not communicate with modem. Will retry later." "unknown" "0"
        return 1
    fi

    # Extract ICCID from modem data
    local current_iccid=""
    current_iccid=$(extract_iccid "$modem_data")
    if [ $? -ne 0 ]; then
        log_message "Failed to extract ICCID from modem data, will retry later" "error"
        update_track "error" "Could not detect SIM card. Please check that a SIM is inserted." "unknown" "0"
        return 1
    fi

    log_message "Current ICCID: $current_iccid" "info"

    # Find profile for current ICCID
    local profile_index=""
    profile_index=$(find_profile_by_iccid "$current_iccid")
    local profile_result=$?

    # CRITICAL FIX: Early return if no profile is found
    if [ $profile_result -ne 0 ]; then
        log_message "No profile found for ICCID $current_iccid, nothing to apply" "info"
        update_track "idle" "No profile exists for current SIM card. Create a profile to configure network settings." "$current_iccid" "0"
        return 0
    fi

    # Only continue if we found a valid profile
    log_message "Found valid profile index: $profile_index" "debug"

    # Get profile details
    local profile_name=$(uci -q get quecprofiles.$profile_index.name)
    local network_type=$(uci -q get quecprofiles.$profile_index.network_type)
    local lte_bands=$(uci -q get quecprofiles.$profile_index.lte_bands)
    local sa_nr5g_bands=$(uci -q get quecprofiles.$profile_index.sa_nr5g_bands)
    local nsa_nr5g_bands=$(uci -q get quecprofiles.$profile_index.nsa_nr5g_bands)
    local apn=$(uci -q get quecprofiles.$profile_index.apn)
    local pdp_type=$(uci -q get quecprofiles.$profile_index.pdp_type)
    local imei=$(uci -q get quecprofiles.$profile_index.imei)
    local ttl=$(uci -q get quecprofiles.$profile_index.ttl)

    # Default pdp_type to "IP" if not specified
    pdp_type="${pdp_type:-IP}"
    # Default TTL to 0 (disabled) if not specified
    ttl="${ttl:-0}"

    # For backward compatibility - check if old nr5g_bands exists but new fields don't
    local nr5g_bands=$(uci -q get quecprofiles.$profile_index.nr5g_bands)
    if [ -n "$nr5g_bands" ] && [ -z "$sa_nr5g_bands" ] && [ -z "$nsa_nr5g_bands" ]; then
        sa_nr5g_bands=$nr5g_bands
        nsa_nr5g_bands=$nr5g_bands
        log_message "Migrating legacy nr5g_bands for profile $profile_name" "info"
    fi

    log_message "Found profile: $profile_name for ICCID: $current_iccid" "info"
    log_message "Profile settings: network_type=$network_type, lte_bands=$lte_bands, sa_nr5g_bands=$sa_nr5g_bands, nsa_nr5g_bands=$nsa_nr5g_bands, apn=$apn, pdp_type=$pdp_type, imei=$imei, ttl=$ttl" "info"

    # Check if APN is configured - it's the minimum required setting
    if [ -z "$apn" ]; then
        log_message "Profile has no APN configured, cannot apply" "error"
        update_track "error" "Profile \"$profile_name\" is missing the required APN setting. Please edit the profile and add an APN." "$profile_name" "0"
        return 1
    fi

    # Check if profile is already applied (unless forced)
    if [ "$forced" != "1" ] && is_profile_applied "$current_iccid" "$profile_name"; then
        log_message "Profile '$profile_name' is already applied, skipping" "info"
        update_track "success" "Profile already applied (from flag)" "$profile_name" "100"
        return 0
    fi

    # Apply profile if forced or if autoswitch is enabled
    local enable_autoswitch
    enable_autoswitch=$(uci -q get quecprofiles.settings.enable_autoswitch)
    enable_autoswitch="${enable_autoswitch:-1}" # Default to enabled

    if [ "$forced" = "1" ] || [ "$enable_autoswitch" = "1" ]; then
        log_message "Applying profile settings..." "info"
        update_track "applying" "Applying profile settings" "$profile_name" "10"

        # Extract current modem settings for comparison
        local current_apn=""
        local current_mode=""
        local current_lte_bands=""
        local current_sa_nr5g_bands=""
        local current_nsa_nr5g_bands=""
        local current_imei=""

        current_apn=$(extract_apn "$modem_data")
        current_mode=$(extract_network_mode "$modem_data")
        current_lte_bands=$(extract_lte_bands "$modem_data")
        current_sa_nr5g_bands=$(extract_nr5g_bands "$modem_data" "sa")
        current_nsa_nr5g_bands=$(extract_nr5g_bands "$modem_data" "nsa")
        current_imei=$(extract_imei "$modem_data")

        # Apply profile settings with the new parameters
        apply_profile_settings "$profile_name" "$network_type" "$lte_bands" "$sa_nr5g_bands" "$nsa_nr5g_bands" \
            "$apn" "$pdp_type" "$imei" "$ttl" "$current_apn" "$current_mode" "$current_lte_bands" \
            "$current_sa_nr5g_bands" "$current_nsa_nr5g_bands" "$current_imei" "$current_iccid"
        return $?
    else
        log_message "Automatic profile switching is disabled, not applying profile" "info"
        update_track "idle" "Automatic profile switching is disabled" "$profile_name" "0"
        return 0
    fi
}

# Main function
main() {
    log_message "QuecProfiles daemon starting with SA/NSA NR5G and TTL support (PID: $$)" "info"

    # Clear status files at startup
    rm -f "$TRACK_FILE" "$CHECK_TRIGGER"
    update_track "idle" "Daemon started" "none" "0"

    # Get check interval from UCI
    local check_interval
    check_interval=$(uci -q get quecprofiles.settings.check_interval)
    check_interval="${check_interval:-$DEFAULT_CHECK_INTERVAL}"

    # Check autoswitch setting
    local enable_autoswitch
    enable_autoswitch=$(uci -q get quecprofiles.settings.enable_autoswitch)
    enable_autoswitch="${enable_autoswitch:-1}" # Default to enabled

    log_message "Daemon configured with check_interval=$check_interval seconds, enable_autoswitch=$enable_autoswitch" "info"

    # Add a startup delay
    log_message "Waiting 10 seconds before initial check..." "info"
    sleep 10

    # Main loop
    while true; do
        # Check if there's a manual check request
        if [ -f "$CHECK_TRIGGER" ]; then
            log_message "Manual check triggered" "info"
            rm -f "$CHECK_TRIGGER"
            check_profile 1 # Forced check
        elif [ "$enable_autoswitch" -eq 1 ]; then
            # Perform regular check
            check_profile 0 # Regular check
        else
            log_message "Automatic profile switching is disabled" "info"
            update_track "idle" "Automatic profile switching is disabled" "none" "0"
        fi

        # Sleep for the check interval
        log_message "Sleeping for $check_interval seconds" "info"

        # Break the sleep into smaller intervals to check for triggers
        sleep_counter=0
        while [ $sleep_counter -lt $check_interval ]; do
            sleep 5
            sleep_counter=$((sleep_counter + 5))
            
            # Check for manual trigger during sleep
            if [ -f "$CHECK_TRIGGER" ]; then
                log_message "Manual check triggered during sleep" "info"
                break
            fi
        done
    done
}

# Set up trap handlers for clean shutdown
trap 'log_message "Received SIGTERM, exiting"; update_track "idle" "Daemon stopped" "none" "0"; exit 0' TERM
trap 'log_message "Received SIGINT, exiting"; update_track "idle" "Daemon stopped" "none" "0"; exit 0' INT

# Start the main function
main