#!/bin/sh

# Set the content type to JSON
echo "Content-Type: application/json"
echo ""

# Run ethtool on eth0 and capture the output
ethtool_output=$(ethtool eth0)

# Extract Link Speed
speed=$(echo "$ethtool_output" | grep "Speed:" | awk '{print $2}')

# Extract Link Status
link_status=$(echo "$ethtool_output" | grep "Link detected:" | awk '{print $3}')

# Extract Auto-negotiation status
auto_negotiation=$(echo "$ethtool_output" | grep "Auto-negotiation:" | awk '{print $2}')

# Create JSON output
echo "{\"link_speed\": \"$speed\", \"link_status\": \"$link_status\", \"auto_negotiation\": \"$auto_negotiation\"}"