#!/bin/bash

# Define executable files path
MENU_SH=/usrdata/simpleadmin/console/menu

# Display Messages in Colors
display_random_color() {
    local msg="$1"
    local colors=(33 34 35 36 37)  # ANSI color codes for yellow, blue, magenta, cyan, white
    local num_colors=${#colors[@]}
    local random_color_index=$(($RANDOM % num_colors))  # Pick a random index from the colors array
    echo -e "\033[${colors[$random_color_index]}m$msg\033[0m"
}

display_green() {
    echo -e "\033[0;32m$1\033[0m"
}

display_red() {
    echo -e "\033[0;31m$1\033[0m"
}

# Menus

toolkit_menu() {
    while true; do
        display_random_color "Run a Toolkit version"
        display_green "Select an option:"
        echo "------------------"
        display_green "1. Get and run the Toolkit"
        display_random_color "2. Get and run the Development/unstable Toolkit"
        display_random_color "3. Exit (Enter Root Shell)"
        echo
        read -p "Select an option (1-3): " option

        case "$option" in
            1) cd /tmp && wget -O RMxxx_rgmii_toolkit.sh https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/RMxxx_rgmii_toolkit.sh && chmod +x RMxxx_rgmii_toolkit.sh && ./RMxxx_rgmii_toolkit.sh && cd / ;;
            2) cd /tmp && wget -O RMxxx_rgmii_toolkit.sh https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/development/RMxxx_rgmii_toolkit.sh && chmod +x RMxxx_rgmii_toolkit.sh && ./RMxxx_rgmii_toolkit.sh && cd / ;;
            3) break ;;
            *) echo "Invalid option. Please try again." ;;
        esac
    done
}

apps_menu() {
    while true; do
        display_random_color "Run a modem App"
        display_green "Select an option:"
        echo "------------------"
        display_random_color "1. Open File Browser/Editor (mc)"
        display_random_color "2. View Used/Available space"
        display_random_color "3. Open Task Manager/View CPU Load"
        display_random_color "4. Run speedtest.net test"
        display_random_color "5. Run fast.com test (30Mbps max)"
        display_green "6. Go Back"
        echo
        read -p "Select an option (1-6): " option

        case "$option" in
            1) mc ;;
            2) dfc ;;
            3) htop ;;
            4) speedtest ;;
            5) fast ;;
            6) break ;;
            *) echo "Invalid option. Please try again." ;;
        esac
    done
}

settings_menu() {
    while true; do
        display_random_color "Welcome to" && display_green "iamromulan's" && display_random_color "Simple Console Menu"
        display_green "Select an option:"
        echo "------------------"
        display_green "1. LAN Settings"
        display_green "2. simplefirewall settings (TTL and Port Block)"
        display_green "3. Change simpleadmin (admin) password"
        display_green "4. Change root password (shell/ssh/console)"
        display_green "5. Go back"
        echo
        read -p "Select an option (1-5): " option

        case "$option" in
            1) $MENU_SH/LAN_settings ;;
            2) $MENU_SH/sfirewall_settings ;;
            3) simplepasswd ;;
            4) passwd ;;
            5) break ;;
            *) echo "Invalid option. Please try again." ;;
        esac
    done
}

main_menu() {
    while true; do
        display_green "Welcome to iamromulan's Simple Console Menu"
        display_green "To get back to this from the root shell, just type 'menu'"
        display_green "Select an option:"
        echo "------------------"
        display_random_color "1. Apps"
        display_random_color "2. Settings"
        display_random_color "3. Toolkit"
        display_random_color "4. Exit (Enter Root Shell)"
        echo
        read -p "Select an option (1-4): " option

        case "$option" in
            1) apps_menu ;;
            2) settings_menu ;;
            3) toolkit_menu ;;
            4) break ;;
            *) echo "Invalid option. Please try again." ;;
        esac
    done
}

main_menu
