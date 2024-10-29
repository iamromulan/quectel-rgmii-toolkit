#!/bin/sh
echo "Content-type: application/json"
echo ""

# Get RX and TX bytes from ifconfig eth0
data=$(ifconfig eth0 | grep "RX bytes")

# Extract download (RX) and upload (TX) values using awk
download=$(echo $data | awk '{print $2}' | cut -d':' -f2)
upload=$(echo $data | awk '{print $6}' | cut -d':' -f2)

# Return JSON response
echo "{"
echo "  \"download\": \"$download\","
echo "  \"upload\": \"$upload\""
echo "}"