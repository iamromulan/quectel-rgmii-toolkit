#!/bin/bash

# Display Messages in Colors
display_green() {
    echo -e "\033[0;32m$1\033[0m"
}

display_red() {
    echo -e "\033[0;31m$1\033[0m"
}


    while true; do
        display_green "Welcome to iamromulan's Simple Console Menu"
		display_green "Select an option"
        echo "------------------"
		display_green "Select an option"
        display_green "1. AP Settings"
        display_green "2. Exit (Enter Root Shell)"
        echo
        read -p "Select an option (1-19): " option

        case "$option" in
            1) ap_settings.sh
            2) break;;
            *) echo "Invalid option. Please try again.";;
        esac
    done
}