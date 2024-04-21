#!/bin/bash

# Define the command to execute when the ethernet port breaks
command_to_execute="/usrdata/socat-at-bridge/atcmd 'AT+CFUN=1,1'"

# Define the monitoring function
watch() {
    while true; do
        # Extract the last 60 lines of dmesg and count the specific pattern occurrences
        count=$(dmesg | tail -60 | grep -e "eth0: cmd = 0xff, should be 0x47" -e "eth0: pci link is down" | grep -c "eth0")

        # Check if the count of patterns is 4 or more
        if [ "$count" -ge 4 ]; then
            echo "Condition met, executing command..."
            eval "$command_to_execute"
            # Optionally, add a break here if you want the script to stop after executing the command
            # break
        fi

        # Sleep for 3 seconds before checking again
        sleep 3
    done
}

# Initial delay before starting monitoring
sleep 30
watch
