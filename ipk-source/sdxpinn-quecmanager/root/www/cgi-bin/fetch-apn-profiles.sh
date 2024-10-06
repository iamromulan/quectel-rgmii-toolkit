#!/bin/sh

echo "Content-type: application/json"
echo ""

CONFIG_FILE="/etc/quecmanager/apn_config.txt"

if [ ! -f "$CONFIG_FILE" ]; then
    echo '{"status": "error", "message": "No APN profiles found", "profiles": {}}'
    exit 0
fi

# Function to read config values
get_config_value() {
    local key=$1
    local value=$(grep "^${key}=" "$CONFIG_FILE" | cut -d'=' -f2)
    echo "$value"
}

# Read all profile values
iccidProfile1=$(get_config_value "iccidProfile1")
apnProfile1=$(get_config_value "apnProfile1")
pdpType1=$(get_config_value "pdpType1")
iccidProfile2=$(get_config_value "iccidProfile2")
apnProfile2=$(get_config_value "apnProfile2")
pdpType2=$(get_config_value "pdpType2")

# Construct JSON response
cat << EOF
{
    "status": "success",
    "profiles": {
        "profile1": {
            "iccid": "${iccidProfile1:-}",
            "apn": "${apnProfile1:-}",
            "pdpType": "${pdpType1:-}"
        },
        "profile2": {
            "iccid": "${iccidProfile2:-}",
            "apn": "${apnProfile2:-}",
            "pdpType": "${pdpType2:-}"
        }
    }
}
EOF