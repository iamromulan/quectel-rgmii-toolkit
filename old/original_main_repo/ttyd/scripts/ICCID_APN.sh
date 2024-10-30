#!/bin/sh

# Configuration
DEVICE_FILE="/dev/smd7"
ICCID_FILE="/path/to/iccid_master_file" # Path to the ICCID-APN-IPType master file
TMP_DIR="/tmp"
TIMEOUT=4

# Start listening to device file
start_listening() {
    cat "$DEVICE_FILE" > "$TMP_DIR/device_readout" &
    CAT_PID=$!
}

# Send AT command
send_at_command() {
    local command=$1
    echo -e "${command}\r" > "$DEVICE_FILE"
}

# Wait for and process response
wait_for_response() {
    local start_time=$(date +%s)
    local current_time
    local elapsed_time

    while true; do
        if grep -q "OK" "$TMP_DIR/device_readout" || grep -q "ERROR" "$TMP_DIR/device_readout"; then
            RESPONSE=$(cat "$TMP_DIR/device_readout")
            echo "Response received: $RESPONSE"
            return 0
        fi
        current_time=$(date +%s)
        elapsed_time=$((current_time - start_time))
        if [ "$elapsed_time" -ge "$TIMEOUT" ]; then
            echo "Error: Response timed out."
            return 1
        fi
        sleep 1
    done
}

# Cleanup function
cleanup() {
    kill "$CAT_PID"
    wait "$CAT_PID" 2>/dev/null
    rm -f "$TMP_DIR/device_readout"
}

# Function to send AT command and wait for response
send_and_wait() {
    send_at_command "$1"
    wait_for_response
}

# Function to update the APN
update_apn() {
    local slot=$1
    local apn=$2
    local iptype=$3
    send_and_wait "AT+CGDCONT=$slot,\"$iptype\",\"$apn\""
    if [ $? -eq 0 ]; then
        echo "APN updated successfully."
    else
        echo "Failed to update APN."
    fi
}

# Main Execution
if [ -c "$DEVICE_FILE" ]; then
    start_listening

    # Get ICCID
    send_and_wait "AT+CCID"
    ICCID=$(echo "$RESPONSE" | grep "+CCID" | cut -d ':' -f2 | tr -d '[:space:]')
    echo "ICCID: $ICCID"

    # Check ICCID in master file
    if grep -q "$ICCID" "$ICCID_FILE"; then
        APN=$(grep "$ICCID" "$ICCID_FILE" | cut -d ',' -f2)
        IP_TYPE=$(grep "$ICCID" "$ICCID_FILE" | cut -d ',' -f3)
        IP_TYPE=${IP_TYPE:-"IPV4V6"} # Default to IPV4V6 if not specified

        # Get current APN settings
        send_and_wait "AT+CGDCONT?"
        CURRENT_APN=$(echo "$RESPONSE" | grep "+CGDCONT: 1" | cut -d ',' -f3 | tr -d '"')

        # Compare and update APN if necessary
        if [ "$APN" != "$CURRENT_APN" ]; then
            update_apn 1 "$APN" "$IP_TYPE"
        else
            echo "No APN update needed."
        fi
    else
        echo "ICCID not found in the master file."
    fi

    cleanup
else
    echo "Error: Device $DEVICE_FILE does not exist or is not a character special file."
fi
