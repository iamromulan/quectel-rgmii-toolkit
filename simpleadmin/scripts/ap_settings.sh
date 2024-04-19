#!/bin/bash

CONFIG_FILE="/etc/data/mobileap_cfg.xml"

# Display Messages in Colors
display_green() {
    echo -e "\033[0;32m$1\033[0m"
}

display_red() {
    echo -e "\033[0;31m$1\033[0m"
}

# Check and Install xml binary if not present
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
    /opt/bin/xml ed -L -u "$node" -v "$new_value" "$CONFIG_FILE"
}

# Get Current XML Value
get_current_value() {
    /opt/bin/xml sel -t -v "$1" "$CONFIG_FILE"
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

# Edit DHCP IP Range
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
    atcmd 'AT+CFUN=1,1'  # Ensure this command is correct for your system
    echo "System reboot initiated. Good luck."
}

# Main Menu
main_menu() {
    while true; do
        clear
        display_red "Warning, these changes can break access over the network. Know what you are doing, and be prepared to use ADB to fix this just in case."
        echo "Configuration Menu"
        echo "------------------"
        display_green "1. Edit Gateway IPV4 Address"
        display_green "2. Edit Gateway URL"
        display_green "3. Edit LAN DHCP Start/End Range"
        display_green "4. Edit LAN Subnet Mask"
        display_green "5. Edit DHCPv6 Base address"
        display_green "6. Toggle IPv4 NAT"
        display_green "7. Toggle IPv6 NAT"
        display_green "8. Toggle DHCP Server"
        display_green "9. Toggle DHCPv4"
        display_green "10. Toggle DHCPv6"
        display_green "11. Toggle WAN Autoconnect"
        display_green "12. Toggle WAN AutoReconnect"
        display_green "13. Toggle Roaming"
        display_green "14. Toggle WAN DNSv4 Passthrough"
        display_green "15. Toggle WAN DNSv6 Passthrough"
        display_green "16. Toggle IPPT NAT/Ability to access gateway while in IPPT mode"
        display_green "17. Toggle UPnP"
        display_green "18. Reboot System"
        display_green "19. Exit"
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

# Start by checking and installing xml if necessary, then mount filesystem as rw and run the menu
mount -o remount,rw /
check_and_install_xml
main_menu
