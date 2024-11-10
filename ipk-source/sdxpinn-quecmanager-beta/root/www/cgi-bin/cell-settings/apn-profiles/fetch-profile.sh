#!/bin/sh

echo "Content-type: application/json"
echo ""

CONFIG_FILE="/etc/quecmanager/apn_config.txt"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "{}"
    exit 0
fi

# Read the configuration file
iccidProfile1=$(grep "^iccidProfile1=" "$CONFIG_FILE" | cut -d'=' -f2)
apnProfile1=$(grep "^apnProfile1=" "$CONFIG_FILE" | cut -d'=' -f2)
pdpType1=$(grep "^pdpType1=" "$CONFIG_FILE" | cut -d'=' -f2)
iccidProfile2=$(grep "^iccidProfile2=" "$CONFIG_FILE" | cut -d'=' -f2)
apnProfile2=$(grep "^apnProfile2=" "$CONFIG_FILE" | cut -d'=' -f2)
pdpType2=$(grep "^pdpType2=" "$CONFIG_FILE" | cut -d'=' -f2)

# Build the JSON response
echo "{"

# Add Profile 1 if it exists
if [ -n "$iccidProfile1" ]; then
    echo "  \"profile1\": {"
    echo "    \"iccid\": \"$iccidProfile1\","
    echo "    \"apn\": \"$apnProfile1\","
    echo "    \"pdpType\": \"$pdpType1\""
    echo "  }"

    # Add comma if Profile 2 exists
    [ -n "$iccidProfile2" ] && echo "  ,"
fi

# Add Profile 2 if it exists
if [ -n "$iccidProfile2" ]; then
    echo "  \"profile2\": {"
    echo "    \"iccid\": \"$iccidProfile2\","
    echo "    \"apn\": \"$apnProfile2\","
    echo "    \"pdpType\": \"$pdpType2\""
    echo "  }"
fi

echo "}"