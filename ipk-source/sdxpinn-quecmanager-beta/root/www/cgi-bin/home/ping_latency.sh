#!/bin/sh

# Set the content type to JSON
echo "Content-Type: application/json"
echo ""

# Ping 8.8.8.8 with 5 packets and capture the full output
ping_result=$(ping -c 5 8.8.8.8)

# Check if ping was successful
if [ $? -eq 0 ]; then
    # Extract the average latency using awk
    avg_latency=$(echo "$ping_result" | awk '/avg/ {split($4, a, "/"); print int(a[2])}')
    
    # If average latency was extracted, return it
    if [ ! -z "$avg_latency" ]; then
        echo "{\"connection\": \"ACTIVE\", \"latency\": $avg_latency}"
    else
        echo '{"connection": "ACTIVE", "latency": 0}'
    fi
else
    # Ping failed
    echo '{"connection": "INACTIVE", "latency": 0}'
fi