#!/bin/sh
# Enable debug logging
# exec 1> >(logger -s -t $(basename $0)) 2>&1
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

if [ ! -c "/dev/smd11" ]; then
    log_message "Error: Modem device /dev/smd11 not found"
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
        echo "$command" | atinout - /dev/smd11 - > /tmp/at_response.txt 2>&1
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
        if ! send_at_command "AT+CFUN=0" "Setting radio off"; then
            return 1
        fi
        sleep 2
        
        if [ -n "$earfcn2" ] && [ -n "$pci2" ]; then
            if [ -n "$earfcn3" ] && [ -n "$pci3" ]; then
                send_at_command "AT+QNWLOCK=\"common/4g\",3,$earfcn1,$pci1,$earfcn2,$pci2,$earfcn3,$pci3" "Setting LTE lock (3 cells)"
            else
                send_at_command "AT+QNWLOCK=\"common/4g\",2,$earfcn1,$pci1,$earfcn2,$pci2" "Setting LTE lock (2 cells)"
            fi
        else
            send_at_command "AT+QNWLOCK=\"common/4g\",1,$earfcn1,$pci1" "Setting LTE lock (1 cell)"
        fi
        
        sleep 2
        if ! send_at_command "AT+CFUN=1" "Setting radio on"; then
            return 1
        fi
    fi
    
    # Apply 5G configuration if present
    if [ -n "$nrpci" ] && [ -n "$nrarfcn" ] && [ -n "$scs" ] && [ -n "$band" ]; then
        if ! send_at_command "AT+CFUN=0" "Setting radio off"; then
            return 1
        fi
        sleep 2
        if ! send_at_command "AT+QNWLOCK=\"common/5g\",$nrpci,$nrarfcn,$scs,$band" "Setting 5G lock"; then
            return 1
        fi
        sleep 2
        if ! send_at_command "AT+CFUN=1" "Setting radio on"; then
            return 1
        fi
    fi
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
