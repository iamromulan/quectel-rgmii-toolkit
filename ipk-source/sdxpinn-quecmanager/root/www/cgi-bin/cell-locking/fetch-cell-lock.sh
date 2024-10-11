#!/bin/sh

echo "Content-type: application/json"
echo ""

CONFIG_FILE="/etc/quecmanager/cell_lock_config.txt"

if [ ! -f "$CONFIG_FILE" ]; then
    echo '{"status": "error", "message": "No cell lock configurations found", "configurations": {}}'
    exit 0
fi

# Function to read config values
get_config_value() {
    local key=$1
    local value=$(grep "^$key=" "$CONFIG_FILE" | sed "s/^$key=//")
    # Remove any trailing whitespace or comments
    value=$(echo "$value" | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//')
    echo "$value"
}

# Read LTE configuration values
earfcn1=$(get_config_value "earfcn1")
pci1=$(get_config_value "pci1")
earfcn2=$(get_config_value "earfcn2")
pci2=$(get_config_value "pci2")
earfcn3=$(get_config_value "earfcn3")
pci3=$(get_config_value "pci3")

# Read 5G-SA configuration values
nrarfcn=$(get_config_value "nrarfcn")
nrpci=$(get_config_value "nrpci")
scs=$(get_config_value "scs")
band=$(get_config_value "band")

# Debug output to syslog
logger "fetch-cell-lock: earfcn1=$earfcn1 pci1=$pci1 nrarfcn=$nrarfcn nrpci=$nrpci"

# Construct JSON response
cat << EOF
{
    "status": "success",
    "configurations": {
        "lte": {
            "earfcn1": "${earfcn1:-}",
            "pci1": "${pci1:-}",
            "earfcn2": "${earfcn2:-}",
            "pci2": "${pci2:-}",
            "earfcn3": "${earfcn3:-}",
            "pci3": "${pci3:-}"
        },
        "sa": {
            "nrarfcn": "${nrarfcn:-}",
            "nrpci": "${nrpci:-}",
            "scs": "${scs:-}",
            "band": "${band:-}"
        }
    }
}
EOF