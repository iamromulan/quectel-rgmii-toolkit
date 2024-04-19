#!/bin/bash

CONFIG_FILE="/etc/data/mobileap_cfg.xml"

# Display Messages in Colors
display_green() {
    echo -e "\033[0;32m$1\033[0m"
}

display_red() {
    echo -e "\033[0;31m$1\033[0m"
}

check_and_install_xml() {
    if [ ! -f "/opt/bin/xml" ]; then
        echo "xml binary not found. Attempting to install xmlstarlet..."
        opkg update
        opkg install xmlstarlet
        # Verify installation
        if [ ! -f "/opt/bin/xml" ]; then
            echo "Failed to install xmlstarlet. Exiting..."
            exit 1
        fi
    fi
    echo "xml binary is available."
}
# Edit XML Value
edit_xml_value() {
    local node="$1"
    local new_value="$2"
    xml ed -L -u "$node" -v "$new_value" "$CONFIG_FILE"
}

# Get Current XML Value
get_current_value() {
    xml sel -t -v "$1" "$CONFIG_FILE"
}

# Enable/Disable Menu
enable_disable_menu() {
    local node="$1"
    local current_value=$(get_current_value "$node")
    echo "Current status: $([ "$current_value" == "1" ] && echo "Enabled" || echo "Disabled")"
    echo "1. Enable"
    echo "2. Disable"
    read -p "Choose an option to toggle (1-2): " choice
    local new_value="$([ "$choice" == "1" ] && echo "1" || echo "0")"
    edit_xml_value "$node" "$new_value"
    display_green "After making changes, please reboot to have them take effect."
}

# Edit Simple Value
edit_simple_value() {
    local node="$1"
    local description="$2"
    local current=$(get_current_value "$node")
    echo "Current $description: $current"
    read -p "Enter new $description: " new_value
    edit_xml_value "$node" "$new_value"
    display_green "After making changes, please reboot to have them take effect."
}

# Main Menu
main_menu() {
    while true; do
        clear
        display_red "Warning, these changes can break access over the network. Know what you are doing, and be prepared to use ADB to fix this just in case."
        echo "Configuration Menu"
        echo "------------------"
        echo "1. Edit Gateway IPV4 Address"
        echo "2. Edit Gateway URL"
        echo "3. Edit LAN DHCP Start/End Range"
        echo "4. Edit LAN Subnet Mask"
        echo "5. Edit DHCPv6 Base address"
        echo "6. Toggle IPv4 NAT"
        echo "7. Toggle IPv6 NAT"
        echo "8. Toggle DHCP Server"
        echo "9. Toggle DHCPv4"
        echo "10. Toggle DHCPv6"
        echo "11. Toggle WAN Autoconnect"
        echo "12. Toggle WAN AutoReconnect"
        echo "13. Toggle Roaming"
        echo "14. Toggle WAN DNSv4 Passthrough"
        echo "15. Toggle WAN DNSv6 Passthrough"
        echo "16. Toggle IPPT NAT/Ability to access gateway while in IPPT mode"
        echo "17. Toggle UPnP"
        echo "18. Reboot System"
        echo "19. Exit"
        echo
        read -p "Select an option (1-19): " option

        case "$option" in
            1) edit_simple_value "//MobileAPLanCfg/APIPAddr" "Gateway IPV4 Address";;
            2) edit_simple_value "//MobileAPLanCfg/GatewayURL" "Gateway URL";;
            3) edit_dhcp_range;;
            4) edit_simple_value "//MobileAPLanCfg/SubNetMask" "LAN Subnet Mask";;
            5) edit_simple_value "//MobileAPLanCfg/ULAIPv6BaseAddr" "DHCPv6 Base Address";;
            6) enable_disable_menu "//MobileAPNatCfg/IPv4NATDisable";;
            7) enable_disable_menu "//MobileAPNatv6Cfg/EnableIPv6NAT";;
            8) enable_disable_menu "//MobileAPLanCfg/EnableDHCPServer";;
            9) enable_disable_menu "//MobileAPLanCfg/EnableIPV4";;
            10) enable_disable_menu "//MobileAPLanCfg/EnableIPV6";;
            11) enable_disable_menu "//MobileAPWanCfg/AutoConnect";;
            12) enable_disable_menu "//MobileAPWanCfg/ReConnect";;
            13) enable_disable_menu "//MobileAPWanCfg/Roaming";;
            14) enable_disable_menu "//Dhcpv4Cfg/EnableDhcpv4Dns";;
            15) enable_disable_menu "//Dhcpv6Cfg/EnableDhcpv6Dns";;
            16) enable_disable_menu "//IPPassthroughFeatureWithNAT";;
            17) enable_disable_menu "//MobileAPSrvcCfg/UPnP";;
            18) reboot_system;;
            19) break;;
            *) echo "Invalid option. Please try again.";;
        esac
    done
}

# Function to Edit DHCP IP Range
edit_dhcp_range() {
    local start_ip=$(get_current_value "//MobileAPLanCfg/DHCPCfg/StartIP")
    local end_ip=$(get_current_value "//MobileAPLanCfg/DHCPCfg/EndIP")
    echo "Current Start IP: $start_ip"
    echo "Current End IP: $end_ip"
    read -p "Enter new Start IP: " new_start_ip
    read -p "Enter new End IP: " new_end_ip
    edit_xml_value "//MobileAPLanCfg/DHCPCfg/StartIP" "$new_start_ip"
    edit_xml_value "//MobileAPLanCfg/DHCPCfg/EndIP" "$new_end_ip"
    display_green "After making changes, please reboot to have them take effect."
}

# Reboot the system
reboot_system() {
    echo "Rebooting system..."
    atcmd 'AT+CFUN=1,1'
    echo "Good Luck."
}

# Run the main menu
mount -o remount,rw /
check_and_install_xml
main_menu
