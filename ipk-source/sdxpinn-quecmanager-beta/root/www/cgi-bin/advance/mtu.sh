#!/bin/sh
echo "Content-type: application/json"
echo ""
mtu_firewall_file="/etc/firewall.user.mtu"
network_interface="rmnet_data0"
lan_utils_script="/etc/data/lanUtils.sh"

get_current_mtu() {
    ip link show "$network_interface" | grep -o "mtu [0-9]*" | cut -d' ' -f2
}

update_lanutils_mtu_config() {
    local action="$1"
    if [ "$action" = "add" ]; then
        # Add the MTU firewall file line if not already present
        if ! grep -q "local mtu_firewall_file=/etc/firewall.user.mtu" "$lan_utils_script"; then
            sed -i '/local ttl_firewall_file=\/etc\/firewall.user.ttl/a local mtu_firewall_file=/etc/firewall.user.mtu' "$lan_utils_script"
        fi
    elif [ "$action" = "remove" ]; then
        # Remove the MTU firewall file line if present
        sed -i '/local mtu_firewall_file=\/etc\/firewall.user.mtu/d' "$lan_utils_script"
    fi
}

case "$REQUEST_METHOD" in
    GET)
        # Fetch current MTU
        current_mtu=$(get_current_mtu)
        current_mtu=${current_mtu:-1500}
        
        # Check if custom MTU is configured
        if [ -f "$mtu_firewall_file" ]; then
            echo "{\"isEnabled\": true, \"currentValue\": $current_mtu}"
        else
            echo "{\"isEnabled\": false, \"currentValue\": $current_mtu}"
        fi
        ;;
    
    POST)
        read -r post_data
        mtu_value=$(echo "$post_data" | sed 's/mtu=//')
       
        # Check for disable functionality
        if [ "$mtu_value" = "disable" ]; then
            # Remove the MTU configuration file
            rm -f "$mtu_firewall_file"
            
            # Remove the MTU configuration line from lanUtils.sh
            update_lanutils_mtu_config "remove"
            
            # Get the default MTU
            default_mtu=$(get_current_mtu)
            default_mtu=${default_mtu:-1500}
            
            echo "{\"success\": true, \"message\": \"MTU configuration disabled\", \"currentValue\": $default_mtu}"
            exit 0
        fi
        
        # Validate MTU input
        if ! [[ "$mtu_value" =~ ^[0-9]+$ ]]; then
            echo "{\"success\": false, \"error\": \"Invalid MTU value\"}"
            exit 1
        fi
        
        # Create firewall MTU configuration file with individual interface commands
        > "$mtu_firewall_file" # Clear the file
        for iface in $(ls /sys/class/net | grep '^rmnet_data'); do
            echo "ip link set $iface mtu $mtu_value" >> "$mtu_firewall_file"
        done
        
        # Immediately apply MTU change
        for iface in $(ls /sys/class/net | grep '^rmnet_data'); do
            ip link set "$iface" mtu "$mtu_value"
        done
        
        # Add the MTU configuration line to lanUtils.sh
        update_lanutils_mtu_config "add"
        
        # Run lanUtils.sh to update network configuration
        if [ -f "$lan_utils_script" ]; then
            . "$lan_utils_script"
        fi
        
        echo "{\"success\": true, \"message\": \"MTU configuration updated to $mtu_value\", \"currentValue\": $mtu_value}"
        ;;
    
    *)
        echo "{\"success\": false, \"error\": \"Invalid request method\"}"
        ;;
esac