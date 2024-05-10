#!/bin/sh

# Check if the required parameters are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <phone_number> <message>"
    exit 1
fi

# Assign the provided parameters to variables
phone_number="$1"
message="$2"

# Send the AT command to set the message format to text mode
echo -ne "AT+CMGF=1\r" > microcom -s /dev/ttyOUT2
sleep 1
echo -ne "AT+CNMI=2,1\r" > microcom /dev/ttyOUT2
sleep 1
echo -ne 'AT+CMGS="09938931024"\r' > microcom /dev/ttyOUT2
sleep 1

# Send the message
echo -ne "$message" > microcom /dev/ttyOUT2
echo -ne "\032" > microcom /dev/ttyOUT2

# Wait for the response
sleep 1

# Capture and output the response
runcmd=$(microcom /dev/ttyOUT2)
# echo "Content-type: text/plain"
echo "$runcmd"