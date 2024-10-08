#!/bin/sh

# Parse POST data
read -r QUERY_STRING

# Function to urldecode
urldecode() {
    echo -e "$(echo "$1" | sed 's/+/ /g;s/%\([0-9A-F][0-9A-F]\)/\\x\1/g')"
}

# Function to send AT commands silently
send_at_command() {
    echo "$1" | atinout - /dev/smd7 - >/dev/null 2>&1
}

# Extract reset flags
reset_lte=$(echo "$QUERY_STRING" | grep -o 'reset_lte=[^&]*' | cut -d= -f2)
reset_5g=$(echo "$QUERY_STRING" | grep -o 'reset_5g=[^&]*' | cut -d= -f2)

# Extract LTE values from POST data
earfcn1=$(echo "$QUERY_STRING" | grep -o 'earfcn1=[^&]*' | cut -d= -f2)
pci1=$(echo "$QUERY_STRING" | grep -o 'pci1=[^&]*' | cut -d= -f2)
earfcn2=$(echo "$QUERY_STRING" | grep -o 'earfcn2=[^&]*' | cut -d= -f2)
pci2=$(echo "$QUERY_STRING" | grep -o 'pci2=[^&]*' | cut -d= -f2)
earfcn3=$(echo "$QUERY_STRING" | grep -o 'earfcn3=[^&]*' | cut -d= -f2)
pci3=$(echo "$QUERY_STRING" | grep -o 'pci3=[^&]*' | cut -d= -f2)

# Extract 5G-SA values from POST data
nrarfcn=$(echo "$QUERY_STRING" | grep -o 'nrarfcn=[^&]*' | cut -d= -f2)
nrpci=$(echo "$QUERY_STRING" | grep -o 'nrpci=[^&]*' | cut -d= -f2)
scs=$(echo "$QUERY_STRING" | grep -o 'scs=[^&]*' | cut -d= -f2)
band=$(echo "$QUERY_STRING" | grep -o 'band=[^&]*' | cut -d= -f2)

# URL decode all values
reset_lte=$(urldecode "$reset_lte")
reset_5g=$(urldecode "$reset_5g")
earfcn1=$(urldecode "$earfcn1")
pci1=$(urldecode "$pci1")
earfcn2=$(urldecode "$earfcn2")
pci2=$(urldecode "$pci2")
earfcn3=$(urldecode "$earfcn3")
pci3=$(urldecode "$pci3")
nrarfcn=$(urldecode "$nrarfcn")
nrpci=$(urldecode "$nrpci")
scs=$(urldecode "$scs")
band=$(urldecode "$band")

# Send Content-type header before any other output
echo "Content-type: application/json"
echo ""

# Handle reset requests
if [ "$reset_lte" = "1" ] || [ "$reset_5g" = "1" ]; then
    # Remove configuration files
    rm -f /etc/quecmanager/cell_lock_config.txt
    rm -f /etc/quecmanager/apply_cell_lock.sh

    # Remove from rc.local if present
    sed -i '/\/etc\/quecmanager\/apply_cell_lock.sh/d' /etc/rc.local

    if [ "$reset_lte" = "1" ] && [ "$reset_5g" = "1" ]; then
        send_at_command "AT+QNWLOCK=\"common/4g\",0"
        send_at_command "AT+QNWLOCK=\"common/5g\",0"
        sleep 1
        send_at_command "AT+COPS=2"
        sleep 1
        send_at_command "AT+COPS=0"
        echo '{"status": "success", "message": "All cell lock configurations removed"}'
    elif [ "$reset_lte" = "1" ]; then
        send_at_command "AT+QNWLOCK=\"common/4g\",0"
        sleep 1
        send_at_command "AT+COPS=2"
        sleep 1
        send_at_command "AT+COPS=0"
        echo '{"status": "success", "message": "LTE cell lock configuration removed"}'
    else
        send_at_command "AT+QNWLOCK=\"common/5g\",0"
        sleep 1
        send_at_command "AT+COPS=2"
        sleep 1
        send_at_command "AT+COPS=0"
        echo '{"status": "success", "message": "5G cell lock configuration removed"}'
    fi
    exit 0
fi

# Create the directory structure if it doesn't exist
mkdir -p /etc/quecmanager /var/log/quecmanager

# Create a configuration file to store cell locking profiles
cat >/etc/quecmanager/cell_lock_config.txt <<EOF
# LTE Cell Locking Configuration
earfcn1=$earfcn1
pci1=$pci1
earfcn2=$earfcn2
pci2=$pci2
earfcn3=$earfcn3
pci3=$pci3

# 5G-SA Cell Locking Configuration
nrarfcn=$nrarfcn
nrpci=$nrpci
scs=$scs
band=$band
EOF

# Create the apply_cell_lock.sh script
cat >/etc/quecmanager/apply_cell_lock.sh <<'EOF'
#!/bin/sh

# Create log directory if it doesn't exist
LOG_DIR="/var/log/quecmanager"
mkdir -p "$LOG_DIR"
DEBUG_LOG="$LOG_DIR/cell_lock_debug.log"

# Function to log messages
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $message" >> "$DEBUG_LOG"
}

# Verify required tools
if ! command -v atinout >/dev/null 2>&1; then
    log_message "Error: atinout command not found"
    exit 1
fi

if [ ! -c "/dev/smd7" ]; then
    log_message "Error: Modem device /dev/smd7 not found"
    exit 1
fi

# Function to send AT commands
send_at_command() {
    local command="$1"
    local description="$2"
    local retry_count=0
    local max_retries=3
    
    log_message "Attempting to send command: $command ($description)"
    
    while [ $retry_count -lt $max_retries ]; do
        echo "$command" | atinout - /dev/smd7 - > /tmp/at_response.txt 2>&1
        local result=$(cat /tmp/at_response.txt)
        
        log_message "Attempt $((retry_count + 1)) - Response: $result"
        
        if echo "$result" | grep -q "OK"; then
            log_message "Command successful: $description"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        log_message "Command failed, retry $retry_count of $max_retries"
        sleep 2
    done
    
    log_message "Command failed after $max_retries retries: $description"
    return 1
}

# Function to apply cell lock configuration
apply_cell_lock() {
    local config_file="/etc/quecmanager/cell_lock_config.txt"
    
    if [ ! -f "$config_file" ]; then
        log_message "Configuration file not found"
        return 1
    fi
    
    # Read configuration values
    . "$config_file"
    
    # Test modem responsiveness
    if ! send_at_command "AT" "Testing modem responsiveness"; then
        return 1
    fi
    
    # Apply LTE configuration if present
    if [ -n "$earfcn1" ] && [ -n "$pci1" ]; then        
        if [ -n "$earfcn2" ] && [ -n "$pci2" ]; then
            if [ -n "$earfcn3" ] && [ -n "$pci3" ]; then
                send_at_command "AT+QNWLOCK=\"common/4g\",3,$earfcn1,$pci1,$earfcn2,$pci2,$earfcn3,$pci3" "Setting LTE lock (3 cells)"
            else
                send_at_command "AT+QNWLOCK=\"common/4g\",2,$earfcn1,$pci1,$earfcn2,$pci2" "Setting LTE lock (2 cells)"
            fi
        else
            send_at_command "AT+QNWLOCK=\"common/4g\",1,$earfcn1,$pci1" "Setting LTE lock (1 cell)"
        fi
        
        sleep 1
        if ! send_at_command "AT+COPS=2" "Network Disconnected"; then
            return 1
        fi

        sleep 1
        if ! send_at_command "AT+COPS=0" "Network Reconnected"; then
            return 1
        fi
    fi
    
    # Apply 5G configuration if present
    if [ -n "$nrpci" ] && [ -n "$nrarfcn" ] && [ -n "$scs" ] && [ -n "$band" ]; then

        if ! send_at_command "AT+QNWPREFCFG=\"mode_pref\",NR5G" "Setting network to SA only"; then
            return 1
        fi
        sleep 1

        if ! send_at_command "AT+QNWCFG=\"nr5g_earfcn_lock\",0" "Disable NR5G EARFCN LOCKING"; then
            return 1
        fi
        sleep 1

        if ! send_at_command "AT+QNWLOCK=\"common/5g\",$nrpci,$nrarfcn,$scs,$band" "Setting 5G lock"; then
            return 1
        fi

        sleep 1
        if ! send_at_command "AT+COPS=2" "Network Disconnected"; then
            return 1
        fi

        sleep 1
        if ! send_at_command "AT+COPS=0" "Network Reconnected"; then
            return 1
        fi
    fi
    
    return 0
}

# Main execution
log_message "Starting cell lock configuration"
if apply_cell_lock; then
    log_message "Cell lock configuration applied successfully"
    exit 0
else
    log_message "Failed to apply cell lock configuration"
    exit 1
fi
EOF

# Make the script executable
chmod +x /etc/quecmanager/apply_cell_lock.sh

# Add to rc.local if not already present
if ! grep -q "/etc/quecmanager/apply_cell_lock.sh" /etc/rc.local; then
    sed -i '/exit 0/i sleep 30\n\/etc\/quecmanager\/apply_cell_lock.sh' /etc/rc.local
fi

# Run the script immediately
/etc/quecmanager/apply_cell_lock.sh
result=$?

if [ $result -eq 0 ]; then
    echo '{"status": "success", "message": "Cell lock configurations saved and applied successfully"}'
else
    echo '{"status": "error", "message": "Cell lock configurations saved but failed to apply"}'
fi
