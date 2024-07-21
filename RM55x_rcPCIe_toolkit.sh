#!/bin/sh

#WORK IN PROGRESS

# Define toolkit paths
GITUSER="iamromulan"
GITTREE="development-RM551"
GITMAINTREE="main"
GITDEVTREE="development"
TMP_DIR="/tmp"
USRDATA_DIR="/data"
SOCAT_AT_DIR="/data/socat-at-bridge"
SOCAT_AT_SYSD_DIR="/data/socat-at-bridge/systemd_units"
SIMPLE_ADMIN_DIR="/data/simpleadmin"
SIMPLE_FIREWALL_DIR="/data/simplefirewall"
SIMPLE_FIREWALL_SCRIPT="$SIMPLE_FIREWALL_DIR/simplefirewall.sh"
SIMPLE_FIREWALL_SYSTEMD_DIR="$SIMPLE_FIREWALL_DIR/systemd"

# AT Command Script Variables and Functions
DEVICE_FILE="/dev/smd7"
TIMEOUT=4  # Set a timeout for the response

# Function to remount file system as read-write
remount_rw() {
    mount -o remount,rw /
}

# Function to remount file system as read-only
remount_ro() {
    mount -o remount,ro /
}

# Basic AT commands without socat bridge for fast response commands only
start_listening() {
    cat "$DEVICE_FILE" > /tmp/device_readout &
    CAT_PID=$!
}

send_at_command() {
    echo -e "\e[1;31mThis only works for basic quick responding commands!\e[0m"  # Red
    echo -e "\e[1;36mType 'install' to simply type atcmd in shell from now on\e[0m"
    echo -e "\e[1;36mThe installed version is much better than this portable version\e[0m"
    echo -e "\e[1;32mEnter AT command (or type 'exit' to quit): \e[0m"
    read at_command
    if [ "$at_command" = "exit" ]; then
        return 1
    fi
    
    if [ "$at_command" = "install" ]; then
        install_update_at_socat
        echo -e "\e[1;32mInstalled. Type atcmd from adb shell or ssh to start an AT Command session\e[0m"
        return 1
    fi
    echo -e "${at_command}\r" > "$DEVICE_FILE"
}

wait_for_response() {
    local start_time=$(date +%s)
    local current_time
    local elapsed_time

    echo -e "\e[1;32mCommand sent, waiting for response...\e[0m"
    while true; do
        if grep -qe "OK" -e "ERROR" /tmp/device_readout; then
            echo -e "\e[1;32mResponse received:\e[0m"
            cat /tmp/device_readout
            return 0
        fi
        current_time=$(date +%s)
        elapsed_time=$((current_time - start_time))
        if [ "$elapsed_time" -ge "$TIMEOUT" ]; then
            echo -e "\e[1;31mError: Response timed out.\e[0m"  # Red
            echo -e "\e[1;32mIf the response takes longer than a second or 2 to respond this will not work\e[0m"  # Green
            echo -e "\e[1;36mType install to install the better version of this that will work.\e[0m"  # Cyan
            return 1
        fi
        sleep 1
    done
}

cleanup() {
    kill "$CAT_PID"
    wait "$CAT_PID" 2>/dev/null
    rm -f /tmp/device_readout
}

send_at_commands() {
    if [ -c "$DEVICE_FILE" ]; then
        while true; do
            start_listening
            send_at_command
            if [ $? -eq 1 ]; then
                cleanup
                break
            fi
            wait_for_response
            cleanup
        done
    else
        echo -e "\e[1;31mError: Device $DEVICE_FILE does not exist!\e[0m"
    fi
}

overlay_check() {
    if ! grep -qs '/real_rootfs ' /proc/mounts; then
        echo -e "\e[31mYou have not ran Option 2 yet!!! Please run option 2!!\e[0m"
        return 1
    fi
}

basic_55x_setup() {
    # Check if neither /etc nor /real_rootfs is mounted
    if ! grep -qs '/etc ' /proc/mounts && ! grep -qs '/real_rootfs ' /proc/mounts; then
        # Echo message in red
        echo -e "\033[31mSomething is wrong or this is not an SDXPINN modem.\033[0m"
        echo -e "\033[31mI was expecting either /etc or /real_rootfs to be a mount point.\033[0m"
        exit 1
    fi

    # Check if /etc is mounted
    if grep -qs '/etc ' /proc/mounts; then
        echo "Unmounting /etc..."
        umount -lf /etc
    fi

    # Check if /real_rootfs is mounted
    if grep -qs '/real_rootfs ' /proc/mounts; then
        # Echo message in red
        echo -e "\033[31mThe environment has already been setup. If you want to undo the changes temporarily run service mount-fix stop.\033[0m"
        exit 1
    fi

    cd /etc/init.d/
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/development-SDXPINN/init.d/mount-fix
    # wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/development-SDXPINN/init.d/init-overlay-watchdog
    # Set executable permissions
    chmod +x mount-fix
    # chmod +x init-overlay-watchdog
    cd /
    service mount-fix enable
    # service init-overlay-watchdog enable
    service mount-fix start
    # service init-overlay-watchdog start
    echo -e "\e[92m"
    echo "Mount fix completed!"
    echo "Visit https://github.com/iamromulan for more!"
    echo -e "\e[0m"
}

ttl_setup() {
    local ttl_file="/etc/firewall.user.ttl"
    local lan_utils_script="/etc/data/lanUtils.sh"
    local combine_function="util_combine_iptable_rules"
    local temp_file="/tmp/temp_firewall_user_ttl"

    overlay_check || return

    if [ -f "$ttl_file" ]; then
        while true; do
            echo "Would you like to edit the TTL settings? (yes to continue, exit to quit):"
            read -r response
            if [ "$response" = "exit" ]; then
                echo "Exiting..."
                break
            elif [ "$response" = "yes" ]; then
                if [ ! -s "$ttl_file" ]; then
                    echo -e "\e[31mTTL is not enabled\e[0m"
                else
                    ipv4_ttl=$(grep 'iptables -t mangle -A POSTROUTING' "$ttl_file" | awk '{print $10}')
                    ipv6_ttl=$(grep 'ip6tables -t mangle -A POSTROUTING' "$ttl_file" | awk '{print $10}')
                    echo -e "\e[32mCurrent IPv4 TTL: $ipv4_ttl\e[0m"
                    echo -e "\e[32mCurrent IPv6 TTL: $ipv6_ttl\e[0m"
                fi
                echo -e "\e[32mType 0 to disable TTL\e[0m"
                echo "Enter the TTL value (number only):"
                read -r ttl_value
                if ! [[ "$ttl_value" =~ ^[0-9]+$ ]]; then
                    echo "Invalid input, please enter a number."
                else
                    if [ "$ttl_value" -eq 0 ]; then
                        echo "Disabling TTL..."
                        > "$ttl_file"
                    else
                        echo "Setting TTL to $ttl_value..."
                        echo "iptables -t mangle -A POSTROUTING -o rmnet+ -j TTL --ttl-set $ttl_value" > "$ttl_file"
                        echo "ip6tables -t mangle -A POSTROUTING -o rmnet+ -j HL --hl-set $ttl_value" >> "$ttl_file"
                    fi
                    /bin/bash "$lan_utils_script"
                fi
            fi
        done
    else
        echo "Creating $ttl_file..."
        touch "$ttl_file"

        echo "Modifying $combine_function in $lan_utils_script..."

        # Backup the original script
        cp "$lan_utils_script" "${lan_utils_script}.bak"

        # Check if the function already includes the ttl_firewall_file line
        if ! grep -q "local ttl_firewall_file" "$lan_utils_script"; then
            awk -v RS= -v ORS="\n\n" "/$combine_function/ {sub(/}/, \"  local ttl_firewall_file=/etc/firewall.user.ttl\n\n  #cleanup\n  cat /dev/null > \$firewall_file\n\n  #combine separate files to /etc/firewall.user\n  if [ -f \\\"\$nat_firewall_file\\\" ]; then\n    cat \$nat_firewall_file >> \$firewall_file\n  fi\n  if [ -f \\\"\$porttrigger_firewall_file\\\" ]; then\n    cat \$porttrigger_firewall_file >> \$firewall_file\n  fi\n  if [ -f \\\"\$tcpmss_firewall_filev4\\\" ]; then\n    cat \$tcpmss_firewall_filev4 >> \$firewall_file\n  fi\n  if [ -f \\\"\$tcpmss_firewall_filev6\\\" ]; then\n    cat \$tcpmss_firewall_filev6 >> \$firewall_file\n  fi\n  if [ -f \\\"\$ttl_firewall_file\\\" ]; then\n    cat \$ttl_firewall_file >> \$firewall_file\n  fi\n}\");} 1" "$lan_utils_script" > "$temp_file" && mv "$temp_file" "$lan_utils_script"
        fi
        ttl_setup
    fi
}

# Function for Tailscale Submenu
tailscale_menu() {
    while true; do
        echo -e "\e[1;32mTailscale Menu\e[0m"
        echo -e "\e[1;32m1) Install/Update Tailscale\e[0m"
        echo -e "\e[1;36m2) Configure Tailscale\e[0m"
        echo -e "\e[1;31m3) Return to Main Menu\e[0m"
        read -p "Enter your choice: " tailscale_choice

        case $tailscale_choice in
            1) install_update_tailscale ;;
            2) configure_tailscale ;;
            3) break ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# Function to install, update, or remove Tailscale
install_update_tailscale() {
    echo -e "\e[1;31m2) Installing tailscale from opkg\e[0m"
    opkg install tailscale
    echo -e "\e[1;32mTailscale has been updated/installed.\e[0m"
    echo -e "\e[1;31mTailscale is not up to date!.\e[0m"
    echo -e "\e[1;32mReplace the tailscale and tailscaled binaries with the new ones and run tailscale update.\e[0m"
}

# Function to Configure Tailscale
configure_tailscale() {
    while true; do
        echo "Configure Tailscale"
        echo -e "\e[38;5;40m1) Enable Tailscale Web UI at http://192.168.225.1:8088 (Gateway on port 8088)\e[0m"  # Green
        echo -e "\e[38;5;196m2) Disable Tailscale Web UI\e[0m"  # Red
        echo -e "\e[38;5;27m3) Connect to Tailnet\e[0m"  # Brown
        echo -e "\e[38;5;87m4) Connect to Tailnet with SSH ON\e[0m"  # Light cyan
        echo -e "\e[38;5;105m5) Reconnect to Tailnet with SSH OFF\e[0m"  # Light magenta
        echo -e "\e[38;5;172m6) Disconnect from Tailnet (reconnects at reboot)\e[0m"  # Light yellow
        echo -e "\e[1;31m7) Logout from tailscale account\e[0m"
        echo -e "\e[38;5;27m8) Return to Tailscale Menu\e[0m"
        read -p "Enter your choice: " config_choice

        case $config_choice in
            1) echo -e "\e[38;5;196mNot for the 551 yet\e[0m" ;;  # Red
            2) echo -e "\e[38;5;196mNot for the 551 yet\e[0m" ;;  # Red
            3) tailscale up --accept-dns=false --reset ;;
            4) tailscale up --ssh --accept-dns=false --reset ;;
            5) tailscale up --accept-dns=false --reset ;;
            6) tailscale down ;;
            7) tailscale logout ;;
            8) break ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# Main menu
while true; do
    echo "                           .%+:                              "
    echo "                             .*@@@-.                         "
    echo "                                  :@@@@-                     "
    echo "                                     @@@@#.                  "
    echo "                                      -@@@@#.                "
    echo "       :.                               %@@@@: -#            "
    echo "      .+-                                #@@@@%.+@-          "
    echo "      .#- .                               +@@@@# #@-         "
    echo "    -@*@*@%                                @@@@@::@@=        "
    echo ".+%@@@@@@@@@%=.                            =@@@@# #@@- ..    "
    echo "    .@@@@@:                                :@@@@@ =@@@..%=   "
    echo "    -::@-.+.                                @@@@@.=@@@- =@-  "
    echo "      .@-                                  .@@@@@:.@@@*  @@. "
    echo "      .%-                                  -@@@@@:=@@@@  @@# "
    echo "      .#-         .%@@@@@@#.               +@@@@@.#@@@@  @@@."
    echo "      .*-            .@@@@@@@@@@=.         @@@@@@ @@@@@  @@@:"
    echo "       :.             .%@@@@@@@@@@@%.     .@@@@@+:@@@@@  @@@-"
    echo "                        -@@@@@@@@@@@@@@@..@@@@@@.-@@@@@ .@@@-"
    echo "                         -@@@@@@@@@@%.  .@@@@@@. @@@@@+ =@@@="
    echo "                           =@@@@@@@@*  .@@@@@@. @@@@@@..@@@@-"
    echo "                            #@@@@@@@@-*@@@@@%..@@@@@@+ #@@@@-"
    echo "                            @@@@@@:.-@@@@@@.  @@@@@@= %@@@@@."
    echo "                           .@@@@. *@@@@@@- .+@@@@@@-.@@@@@@+ "
    echo "                           %@@. =@@@@@*.  +@@@@@@%.-@@@@@@%  "
    echo "                          .@@ .@@@@@=  :@@@@@@@@..@@@@@@@=   "
    echo "                          =@.+@@@@@. -@@@@@@@*.:@@@@@@@*.    "
    echo "                          %.*@@@@= .@@@@@@@-.:@@@@@@@+.      "
    echo "                          ..@@@@= .@@@@@@: #@@@@@@@:         "
    echo "                           .@@@@  +@@@@..%@@@@@+.            "
    echo "                           .@@@.  @@@@.:@@@@+.               "
    echo "                            @@@.  @@@. @@@*    .@.           "
    echo "                            :@@@  %@@..@@#.    *@            "
    echo "                         -*: .@@* :@@. @@.  -..@@            "
    echo "                       =@@@@@@.*@- :@%  @* =@:=@#            "
    echo "                      .@@@-+@@@@:%@..%- ...@%:@@:            "
    echo "                      .@@.  @@-%@:      .%@@*@@%.            "
    echo "                       :@@ :+   *@     *@@#*@@@.             "
    echo "                                     =@@@.@@@@               "
    echo "                                  .*@@@:=@@@@:               "
    echo "                                .@@@@:.@@@@@:                "
    echo "                              .@@@@#.-@@@@@.                 "
    echo "                             #@@@@: =@@@@@-                  "
    echo "                           .@@@@@..@@@@@@*                   "
    echo "                          -@@@@@. @@@@@@#.                   "
    echo "                         -@@@@@  @@@@@@%                     "
    echo "                         @@@@@. #@@@@@@.                     "
    echo "                        :@@@@# =@@@@@@%                      "
    echo "                        @@@@@: @@@@@@@:                      "
    echo "                        *@@@@  @@@@@@@.                      "
    echo "                        .@@@@  @@@@@@@                       "
    echo "                         #@@@. @@@@@@*                       "
    echo "                          @@@# @@@@@@@                       "
    echo "                           .@@+=@@@@@@.                      "
    echo "                                *@@@@@@                      "
    echo "                                 :@@@@@=                     "
    echo "                                  .@@@@@@.                   "
    echo "                                    :@@@@@*.                 "
    echo "                                      .=@@@@@-               "
    echo "                                           :+##+.            "

    echo -e "\e[92m"
    echo "Welcome to iamromulan's rcPCIe Toolkit script for Quectel RM55x Series modems!"
    echo "Visit https://github.com/iamromulan for more!"
    echo -e "\e[0m"
    echo -e "\e[91mThis is a test version of the toolkit for the new RM550/551 modems\e[0m" # Light Red
    echo "Select an option:"
    echo -e "\e[0m"
    echo -e "\e[96m1) Send AT Commands\e[0m" # Cyan
    echo -e "\e[92m2) First time setup/run me after a flash!\e[0m" # Green
    echo -e "\e[94m3) TTL Setup\e[0m" # Light Blue
    echo -e "\e[94m4) Set root password\e[0m" # Light Blue
    echo -e "\e[94m5) Tailscale Management\e[0m" # Light Blue
    echo -e "\e[92m6) Install Speedtest.net CLI app (speedtest command)\e[0m" # Light Green
    echo -e "\e[93m7) Exit\e[0m" # Yellow (repeated color for exit option)
    read -p "Enter your choice: " choice

    case $choice in
        1) send_at_commands ;;
        2) remount_rw; basic_55x_setup ;;
        3) 
            overlay_check
            if [ $? -eq 1 ]; then continue; fi
            ttl_setup 
            ;;
        4) 
            overlay_check
            if [ $? -eq 1 ]; then continue; fi
            set_root_passwd 
            ;;
        5) tailscale_menu ;;
        6)
            overlay_check
            if [ $? -eq 1 ]; then continue; fi
            echo -e "\e[1;32mInstalling Speedtest.net CLI (speedtest command)\e[0m"
            # Add Logic to confirm we are overlayed over the larger /data
            cd /usr/bin
            wget https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz
            tar -xzf ookla-speedtest-1.2.0-linux-aarch64.tgz
            rm ookla-speedtest-1.2.0-linux-aarch64.tgz
            rm speedtest.md
            cd /
            echo -e "\e[1;32mSpeedtest CLI (speedtest command) installed!!\e[0m"
            echo -e "\e[1;32mTry running the command 'speedtest'\e[0m"
            echo -e "\e[1;32mNote that it will not work unless you login to the root account first\e[0m"
            echo -e "\e[1;32mNormally only an issue in adb, ttyd, and ssh you are forced to login\e[0m"
            echo -e "\e[1;32mIf in adb just type login and then try to run the speedtest command\e[0m"
            ;;
        7) echo -e "\e[1;32mGoodbye!\e[0m"; break ;;
        *) echo -e "\e[1;31mInvalid option\e[0m" ;;
    esac
done
