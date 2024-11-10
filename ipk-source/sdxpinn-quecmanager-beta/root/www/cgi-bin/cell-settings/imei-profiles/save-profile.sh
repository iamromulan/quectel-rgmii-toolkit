#!/bin/sh

# Parse POST data
read -r QUERY_STRING

# Function to urldecode
urldecode() {
    echo -e "$(echo "$1" | sed 's/+/ /g;s/%\([0-9A-F][0-9A-F]\)/\\x\1/g')"
}

# Extract values from POST data
iccidProfile1=$(echo "$QUERY_STRING" | grep -o 'iccidProfile1=[^&]*' | cut -d= -f2)
imeiProfile1=$(echo "$QUERY_STRING" | grep -o 'imeiProfile1=[^&]*' | cut -d= -f2)
iccidProfile2=$(echo "$QUERY_STRING" | grep -o 'iccidProfile2=[^&]*' | cut -d= -f2)
imeiProfile2=$(echo "$QUERY_STRING" | grep -o 'imeiProfile2=[^&]*' | cut -d= -f2)

# URL decode the values
iccidProfile1=$(urldecode "$iccidProfile1")
imeiProfile1=$(urldecode "$imeiProfile1")
iccidProfile2=$(urldecode "$iccidProfile2")
imeiProfile2=$(urldecode "$imeiProfile2")

echo "Content-type: application/json"
echo ""

# Validate required first profile
if [ -z "$iccidProfile1" ] || [ -z "$imeiProfile1" ]; then
    echo '{"status": "error", "message": "Profile 1 is required"}'
    exit 1
fi

# Check the directory if it exists, if not create it
if [ ! -d /etc/quecmanager ]; then
    mkdir -p /etc/quecmanager
fi

# Create a configuration file to store IMEI profiles
cat > /etc/quecmanager/imei_config.txt << EOF
iccidProfile1=$iccidProfile1
imeiProfile1=$imeiProfile1
EOF

# Add second profile only if ICCID is provided
if [ -n "$iccidProfile2" ]; then
    cat >> /etc/quecmanager/imei_config.txt << EOF
iccidProfile2=$iccidProfile2
imeiProfile2=$imeiProfile2
EOF
fi

# Create the imeiProfiles.sh script
cat > /etc/quecmanager/imeiProfiles.sh << 'EOF'
#!/bin/sh

# Function to read config values
get_config_value() {
    local key=$1
    grep "^${key}=" /etc/quecmanager/imei_config.txt | cut -d'=' -f2
}

# Read configuration
iccidProfile1=$(get_config_value "iccidProfile1")
imeiProfile1=$(get_config_value "imeiProfile1")
iccidProfile2=$(get_config_value "iccidProfile2")
imeiProfile2=$(get_config_value "imeiProfile2")

# Debug logging
DEBUG_LOG="/tmp/debug.log"
echo "Starting IMEI profile script at $(date)" > "$DEBUG_LOG"

CONFIG_FILE="/etc/quecManager.conf"
# Check config file
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file not found: $CONFIG_FILE" >> "$DEBUG_LOG"
    echo '{"error": "Config file not found"}'
    exit 1
fi

# Get AT_PORT with debug logging
AT_PORT=$(head -n 1 "$CONFIG_FILE" | cut -d'=' -f2 | tr -d ' \n\r' | sed 's|^dev/||')
echo "Raw config line: $(head -n 1 "$CONFIG_FILE")" >> "$DEBUG_LOG"
echo "Extracted AT_PORT: '$AT_PORT'" >> "$DEBUG_LOG"

if [ -z "$AT_PORT" ]; then
    echo "AT_PORT is empty" >> "$DEBUG_LOG"
    echo '{"error": "Failed to read AT_PORT from config"}'
    exit 1
fi

# Check if AT_PORT exists
if [ ! -c "/dev/$AT_PORT" ]; then
    echo "AT_PORT device not found: /dev/$AT_PORT" >> "$DEBUG_LOG"
    echo '{"error": "AT_PORT device not found"}'
    exit 1
fi

# Function to get current ICCID
get_current_iccid() {
    local input_file="/tmp/inputICCID.txt"
    local output_file="/tmp/outputICCID.txt"
    
    echo "AT+ICCID" > "$input_file"
    atinout "$input_file" "/dev/$AT_PORT" "$output_file"
    
    iccid=$(cat "$output_file" | grep "+ICCID:" | cut -d' ' -f2)
    
    rm -f "$input_file" "$output_file"
    echo "$iccid"
}

# Function to set IMEI
set_imei() {
    local imei="$1"
    local input_file="/tmp/inputIMEI.txt"
    local output_file="/tmp/outputIMEI.txt"
    
    echo "AT+EGMR=1,7,\"$imei\";+QPOWD=1" > "$input_file"
    atinout "$input_file" "/dev/$AT_PORT" "$output_file"
    
    local result=$(cat "$output_file")
    rm -f "$input_file" "$output_file"
    
    if echo "$result" | grep -q "OK"; then
        return 0
    else
        return 1
    fi
}

# Get current ICCID
current_iccid=$(get_current_iccid)
success=false

# Check ICCID against profile 1 (required)
if [ "$current_iccid" = "$iccidProfile1" ]; then
    if set_imei "$imeiProfile1"; then
        success=true
    fi
# Check ICCID against profile 2 (optional)
elif [ -n "$iccidProfile2" ] && [ "$current_iccid" = "$iccidProfile2" ]; then
    if set_imei "$imeiProfile2"; then
        success=true
    fi
fi

if [ "$success" = "true" ]; then
    echo "IMEI set successfully" > /tmp/imei_result.txt
else
    echo "Failed to set IMEI" > /tmp/imei_result.txt
fi
EOF

# Make the script executable
chmod +x /etc/quecmanager/imeiProfiles.sh

# Add to rc.local if not already present
if ! grep -q "/etc/quecmanager/imeiProfiles.sh" /etc/rc.local; then
    sed -i '/^exit 0/i /etc/quecmanager/imeiProfiles.sh' /etc/rc.local
fi

# Run the script immediately
/etc/quecmanager/imeiProfiles.sh

# Check the result
if [ -f /tmp/imei_result.txt ]; then
    result=$(cat /tmp/imei_result.txt)
    rm -f /tmp/imei_result.txt
    
    if [ "$result" = "IMEI set successfully" ]; then
        echo '{"status": "success", "message": "IMEI profiles saved and applied successfully"}'
    else
        echo '{"status": "error", "message": "IMEI profiles saved but failed to apply"}'
    fi
else
    echo '{"status": "error", "message": "Something went wrong while processing IMEI profiles"}'
fi