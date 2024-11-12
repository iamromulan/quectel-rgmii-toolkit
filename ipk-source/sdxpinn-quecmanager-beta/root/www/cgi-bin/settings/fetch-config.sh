#!/bin/sh
# Set the content type to JSON
echo "Content-Type: application/json"
echo ""

# Configuration file path
CONFIG_FILE="/etc/quecManager.conf"

# Check if the config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo '{"error": "Configuration file not found"}'
    exit 1
fi

# Initialize variables
AT_PORT=""
AT_PORT_CUSTOM=""
DATA_REFRESH_RATE=""

# Read the config file line by line and extract values
while IFS='=' read -r key value; do
    # Remove leading/trailing whitespace
    key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    case "$key" in
    "AT_port") AT_PORT="$value" ;;
    "AT_port_custom") AT_PORT_CUSTOM="$value" ;;
    "data_refresh_rate") DATA_REFRESH_RATE="$value" ;;
    esac
done <"$CONFIG_FILE"

# Output JSON
echo "{"
echo "  \"AT_port\": \"$AT_PORT\","
echo "  \"AT_port_custom\": \"$AT_PORT_CUSTOM\","
echo "  \"data_refresh_rate\": $DATA_REFRESH_RATE"
echo "}"