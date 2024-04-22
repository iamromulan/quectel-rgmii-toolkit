#!/bin/bash

SIMPLE_FIREWALL_DIR="/usrdata/simplefirewall"
SIMPLE_FIREWALL_SCRIPT="$SIMPLE_FIREWALL_DIR/simplefirewall.sh"
SIMPLE_FIREWALL_SYSTEMD_DIR="$SIMPLE_FIREWALL_DIR/systemd"

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

set_portblocks() {
        current_ports_line=$(grep '^PORTS=' "$SIMPLE_FIREWALL_SCRIPT")
        ports=$(echo "$current_ports_line" | cut -d'=' -f2 | tr -d '()' | tr ' ' '\n' | grep -o '[0-9]\+')
        echo -e "\e[1;32mCurrent configured ports:\e[0m"
        echo "$ports" | awk '{print NR") "$0}'

        while true; do
            echo -e "\e[1;32mEnter a port number to add/remove, or type 'done' or 'exit' to finish:\e[0m"
            read port
            if [ "$port" = "done" ] || [ "$port" = "exit" ]; then
                if [ "$port" = "exit" ]; then
                    echo -e "\e[1;31mExiting without making changes...\e[0m"
                    return
                fi
                break
            elif ! echo "$port" | grep -qE '^[0-9]+$'; then
                echo -e "\e[1;31mInvalid input: Please enter a numeric value.\e[0m"
            elif echo "$ports" | grep -q "^$port\$"; then
                ports=$(echo "$ports" | grep -v "^$port\$")
                echo -e "\e[1;32mPort $port removed.\e[0m"
            else
                ports=$(echo "$ports"; echo "$port" | grep -o '[0-9]\+')
                echo -e "\e[1;32mPort $port added.\e[0m"
            fi
        done

        if [ "$port" != "exit" ]; then
            new_ports_line="PORTS=($(echo "$ports" | tr '\n' ' '))"
            sed -i "s/$current_ports_line/$new_ports_line/" "$SIMPLE_FIREWALL_SCRIPT"
        fi
}

set_ttl(){
# TTL configuration code
        ttl_value=$(cat /usrdata/simplefirewall/ttlvalue)
        if [ "$ttl_value" -eq 0 ]; then
            echo -e "\e[1;31mTTL is not set.\e[0m"
        else
            echo -e "\e[1;32mTTL value is set to $ttl_value.\e[0m"
        fi

        echo -e "\e[1;31mType 'exit' to cancel.\e[0m"
        read -p "What do you want the TTL value to be: " new_ttl_value
        if [ "$new_ttl_value" = "exit" ]; then
            echo -e "\e[1;31mExiting TTL configuration...\e[0m"
            return
        elif ! echo "$new_ttl_value" | grep -qE '^[0-9]+$'; then
            echo -e "\e[1;31mInvalid input: Please enter a numeric value.\e[0m"
            return
        else
            /usrdata/simplefirewall/ttl-override stop
	    echo "$new_ttl_value" > /usrdata/simplefirewall/ttlvalue
     	    /usrdata/simplefirewall/ttl-override start
            echo -e "\033[0;32mTTL value updated to $new_ttl_value.\033[0m"
        fi
}

# function to configure the fetures of simplefirewall
simple_firewall_menu() {
    if [ ! -f "$SIMPLE_FIREWALL_SCRIPT" ]; then
        echo -e "\033[0;31mSimplefirewall is not installed, would you like to install it?\033[0m"
        echo -e "\033[0;32m1) Yes\033[0m"
        echo -e "\033[0;31m2) No\033[0m"
        read -p "Enter your choice (1-2): " install_choice

        case $install_choice in
            1)
                install_simple_firewall
                ;;
            2)
                return
                ;;
            *)
                echo -e "\033[0;31mInvalid choice. Please select either 1 or 2.\033[0m"
                ;;
        esac
    fi

    echo -e "\e[1;32mConfigure Simple Firewall:\e[0m"
    echo -e "\e[38;5;208m1) Configure incoming port block\e[0m"
    echo -e "\e[38;5;27m2) Configure TTL\e[0m"
    read -p "Enter your choice (1-2): " menu_choice

    case $menu_choice in
    1)
		set_portblocks
        ;;
    2)
        set_ttl
        ;;
    *)
        echo -e "\e[1;31mInvalid choice. Please select either 1 or 2.\e[0m"
        ;;
    esac

    systemctl restart simplefirewall
    echo -e "\e[1;32mFirewall configuration updated.\e[0m"
}

# Start by checking and installing xml if necessary, then mount filesystem as rw and run the menu
mount -o remount,rw /
simple_firewall_menu