#!/bin/sh
echo "Content-type: application/json"
echo ""

CONFIG_FILE="/etc/quecmanager/imei_config.txt"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "{}"
    exit 0
fi

# Read the configuration file
iccidProfile1=$(grep "^iccidProfile1=" "$CONFIG_FILE" | cut -d'=' -f2)
imeiProfile1=$(grep "^imeiProfile1=" "$CONFIG_FILE" | cut -d'=' -f2)
iccidProfile2=$(grep "^iccidProfile2=" "$CONFIG_FILE" | cut -d'=' -f2)
imeiProfile2=$(grep "^imeiProfile2=" "$CONFIG_FILE" | cut -d'=' -f2)

# Build the JSON response
echo "{"

# Add Profile 1 if it exists
if [ -n "$iccidProfile1" ]; then
    echo "  \"profile1\": {"
    echo "    \"iccid\": \"$iccidProfile1\","
    echo "    \"imei\": \"$imeiProfile1\""
    echo "  }"
    # Add comma if Profile 2 exists
    [ -n "$iccidProfile2" ] && echo "  ,"
fi

# Add Profile 2 if it exists
if [ -n "$iccidProfile2" ]; then
    echo "  \"profile2\": {"
    echo "    \"iccid\": \"$iccidProfile2\","
    echo "    \"imei\": \"$imeiProfile2\""
    echo "  }"
fi

echo "}"