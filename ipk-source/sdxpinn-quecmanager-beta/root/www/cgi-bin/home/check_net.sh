#!/bin/sh

# Set the content type to JSON
echo "Content-Type: application/json"
echo ""

# Ping 8.8.8.8 with 5 packets and capture the result
if ping -c 5 8.8.8.8 > /dev/null 2>&1; then
    # Ping was successful
    echo '{"connection": "ACTIVE"}'
else
    # Ping failed
    echo '{"connection": "INACTIVE"}'
fi