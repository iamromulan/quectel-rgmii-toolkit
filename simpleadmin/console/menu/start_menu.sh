#!/bin/bash

# Define executable files path
EXE=/usrdata/root/bin

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

toolkit() {
    while true; do
        display_green "Welcome to iamromulan's Simple Console Menu"
        display_green "Select an option:"
        echo "------------------"
        display_green "1. LAN Settings"
        display_green "2. Change simpleadmin (admin) password"
        display_green "3. Change root password (shell/ssh/console)"
        display_green "4. Open File Browser/Editor (mc)"
        display_green "5. View Used/Available space"
        display_green "6. Open Task Manager/View CPU Load"
        display_green "7. Run speedtest.net test"
        display_green "8. Run fast.com test (30Mbps max)"
        display_green "9. Get and run the Toolkit"
        display_green "10. Get and run the Development/unstable Toolkit"
        display_green "11. Exit (Enter Root Shell)"
        echo
        read -p "Select an option (1-11): " option

        case "$option" in
            1) $EXE/LAN_settings ;;
            2) $EXE/simplepasswd ;;
            3) passwd ;;
            4) mc ;;
            5) dfc ;;
            6) htop ;;
            7) $EXE/speedtest ;;
            8) $EXE/fast ;;
            9) cd /tmp && wget -O RMxxx_rgmii_toolkit.sh https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/RMxxx_rgmii_toolkit.sh && chmod +x RMxxx_rgmii_toolkit.sh && ./RMxxx_rgmii_toolkit.sh && cd / ;;
            10) cd /tmp && wget -O RMxxx_rgmii_toolkit.sh https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/development/RMxxx_rgmii_toolkit.sh && chmod +x RMxxx_rgmii_toolkit.sh && ./RMxxx_rgmii_toolkit.sh && cd / ;;
            11) break ;;
            *) echo "Invalid option. Please try again." ;;
        esac
    done
}

apps() {
    while true; do
        display_green "Welcome to iamromulan's Simple Console Menu"
        display_green "Select an option:"
        echo "------------------"
        display_green "1. LAN Settings"
        display_green "2. Change simpleadmin (admin) password"
        display_green "3. Change root password (shell/ssh/console)"
        display_green "4. Open File Browser/Editor (mc)"
        display_green "5. View Used/Available space"
        display_green "6. Open Task Manager/View CPU Load"
        display_green "7. Run speedtest.net test"
        display_green "8. Run fast.com test (30Mbps max)"
        display_green "9. Get and run the Toolkit"
        display_green "10. Get and run the Development/unstable Toolkit"
        display_green "11. Exit (Enter Root Shell)"
        echo
        read -p "Select an option (1-11): " option

        case "$option" in
            1) $EXE/LAN_settings ;;
            2) $EXE/simplepasswd ;;
            3) passwd ;;
            4) mc ;;
            5) dfc ;;
            6) htop ;;
            7) $EXE/speedtest ;;
            8) $EXE/fast ;;
            9) cd /tmp && wget -O RMxxx_rgmii_toolkit.sh https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/RMxxx_rgmii_toolkit.sh && chmod +x RMxxx_rgmii_toolkit.sh && ./RMxxx_rgmii_toolkit.sh && cd / ;;
            10) cd /tmp && wget -O RMxxx_rgmii_toolkit.sh https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/development/RMxxx_rgmii_toolkit.sh && chmod +x RMxxx_rgmii_toolkit.sh && ./RMxxx_rgmii_toolkit.sh && cd / ;;
            11) break ;;
            *) echo "Invalid option. Please try again." ;;
        esac
    done
}

settings() {
    while true; do
        display_green "Welcome to iamromulan's Simple Console Menu"
        display_green "Select an option:"
        echo "------------------"
        display_green "1. LAN Settings"
        display_green "2. Change simpleadmin (admin) password"
        display_green "3. Change root password (shell/ssh/console)"
        display_green "4. Open File Browser/Editor (mc)"
        display_green "5. View Used/Available space"
        display_green "6. Open Task Manager/View CPU Load"
        display_green "7. Run speedtest.net test"
        display_green "8. Run fast.com test (30Mbps max)"
        display_green "9. Get and run the Toolkit"
        display_green "10. Get and run the Development/unstable Toolkit"
        display_green "11. Exit (Enter Root Shell)"
        echo
        read -p "Select an option (1-11): " option

        case "$option" in
            1) $EXE/LAN_settings ;;
            2) $EXE/simplepasswd ;;
            3) passwd ;;
            4) mc ;;
            5) dfc ;;
            6) htop ;;
            7) $EXE/speedtest ;;
            8) $EXE/fast ;;
            9) cd /tmp && wget -O RMxxx_rgmii_toolkit.sh https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/RMxxx_rgmii_toolkit.sh && chmod +x RMxxx_rgmii_toolkit.sh && ./RMxxx_rgmii_toolkit.sh && cd / ;;
            10) cd /tmp && wget -O RMxxx_rgmii_toolkit.sh https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/development/RMxxx_rgmii_toolkit.sh && chmod +x RMxxx_rgmii_toolkit.sh && ./RMxxx_rgmii_toolkit.sh && cd / ;;
            11) break ;;
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
        display_random_color "1) Apps"
        display_random_color "2) Settings"
        display_random_color "3) Toolkit"
        display_random_color "4) Exit (Enter Root Shell)"
        echo
        read -p "Select an option (1-11): " option

        case "$option" in
            1) apps ;;
            2) settings ;;
            3) toolkit ;;
            4) break ;;
            *) echo "Invalid option. Please try again." ;;
        esac
    done
}

main_menu