#!/bin/sh

# Script to configure SMS text mode on a modem device
# Usage: ./sms_config.sh

# Check if atinout is installed
if ! command -v atinout &> /dev/null; then
    echo "Error: atinout is not installed"
    exit 1
fi

# Check if the device exists
if [ ! -c "/dev/smd11" ]; then
    echo "Error: Device /dev/smd11 not found"
    exit 1
fi

# Send AT command to set SMS text mode
if ! echo "AT+CMGF=1" | atinout - /dev/smd11 -; then
    echo "Error: Failed to send AT command"
    exit 1
fi

echo "Successfully configured SMS text mode"