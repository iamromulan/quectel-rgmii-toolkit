#!/bin/bash

# Define the hostname or IP address to ping
HOSTNAME="google.com"

# Number of pings to attempt
PING_COUNT=6

# Initialize a counter for successful pings
success_count=0

# Attempt to ping the specified number of times
for i in $(seq 1 $PING_COUNT); do
    # Ping the hostname with a timeout of 1 second per ping
    if ping -c 1 -W 1 $HOSTNAME &> /dev/null; then
        ((success_count++))
    else
        echo "Ping attempt $i failed."
    fi
done

# Check if all pings failed
if [ $success_count -eq 0 ]; then
    echo "All $PING_COUNT ping attempts failed, executing AT command."
    /bin/atcmd 'AT+CFUN=1,1'
else
    echo "$success_count out of $PING_COUNT ping attempts were successful."
fi
