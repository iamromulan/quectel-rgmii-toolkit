#!/bin/sh
# save-config.sh
echo "Content-Type: application/json"
echo ""

# Read POST data
read -n $CONTENT_LENGTH POST_DATA

# Configuration file path
CONFIG_FILE="/etc/quecManager.conf"

# Parse JSON input and update config file
AT_PORT=$(echo "$POST_DATA" | grep -o '"AT_port":"[^"]*"' | cut -d'"' -f4)
AT_PORT_CUSTOM=$(echo "$POST_DATA" | grep -o '"AT_port_custom":"[^"]*"' | cut -d'"' -f4)
DATA_REFRESH_RATE=$(echo "$POST_DATA" | grep -o '"data_refresh_rate":"[^"]*"' | cut -d'"' -f4)

# Create new config content
cat > "$CONFIG_FILE" << EOF
AT_port = $AT_PORT
AT_port_custom = $AT_PORT_CUSTOM
data_refresh_rate = $DATA_REFRESH_RATE
EOF

# Check if write was successful
if [ $? -eq 0 ]; then
    echo '{"success": true, "message": "Configuration saved successfully"}'
else
    echo '{"success": false, "error": "Failed to save configuration"}'
fi