#!/bin/ash

#WORK IN PROGRESS

# Define toolkit paths
GITUSER="iamromulan"
GITREPO="quectel-rgmii-toolkit"
GITTREE="SDXPINN"
GITMAINTREE="SDXPINN"
GITDEVTREE="development-SDXPINN"
TMP_DIR="/tmp"
USRDATA_DIR="/data"
SIMPLE_FIREWALL_DIR="/data/simplefirewall"
SIMPLE_FIREWALL_SCRIPT="$SIMPLE_FIREWALL_DIR/simplefirewall.sh"
SIMPLE_FIREWALL_SYSTEMD_DIR="$SIMPLE_FIREWALL_DIR/systemd"

# Function to remount file system as read-write
remount_rw() {
    mount -o remount,rw /
}

# Function to remount file system as read-only
remount_ro() {
    mount -o remount,ro /
}

send_at_commands_using_atcmd() {
    while true; do
        echo -e "\e[1;32mEnter AT command (or type 'exit' to return to the main menu): \e[0m"
        read at_command
        if [ "$at_command" = "exit" ]; then
            echo -e "\e[1;32mReturning to the main menu.\e[0m"
            break
        fi
        echo -e "\e[1;32mSending AT command: $at_command\e[0m"
        echo -e "\e[1;32mResponse:\e[0m"
        # Use atcmd to send the command and display the output
        atcmd_output=$(atcmd "$at_command")
        echo "$atcmd_output"
        echo -e "\e[1;32m----------------------------------------\e[0m"
    done
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
    wget https://raw.githubusercontent.com/$GITUSER/$GITREPO/$GITTREE/etc/init.d/mount-fix
    wget https://raw.githubusercontent.com/$GITUSER/$GITREPO/$GITTREE/etc/init.d/init-overlay-watchdog
    # Set executable permissions
    chmod +x mount-fix
    chmod +x init-overlay-watchdog
    cd /usr/sbin
	wget https://raw.githubusercontent.com/$GITUSER/$GITREPO/$GITTREE/usr/sbin/init-overlay-watchdog.sh
	cd /
    service mount-fix enable
    service init-overlay-watchdog enable
    service mount-fix start
	echo "src/gz iamromulan-SDXPINN-repo https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/SDXPINN/opkg-feed" >> /etc/opkg/customfeeds.conf
	rm /etc/opkg/distfeeds.conf
	cd /etc/opkg/
	wget https://raw.githubusercontent.com/$GITUSER/$GITREPO/$GITTREE/etc/opkg/distfeeds.conf
	cd /
	wget https://raw.githubusercontent.com/$GITUSER/$GITREPO/$GITTREE/opkg-feed/iamromulan-SDXPINN-repo.key -O /tmp/iamromulan-SDXPINN-repo.key
    opkg-key add /tmp/iamromulan-SDXPINN-repo.key
	opkg update
	opkg install inotifywait inotifywatch
    service init-overlay-watchdog start
    echo -e "\e[92m"
    echo "Mount fix completed!"
    echo "Visit https://github.com/iamromulan for more!"
	echo "Proceeding with basic packages installation...."	
    echo -e "\e[0m"
	opkg install atinout luci-app-atinout-mod
	opkg install shadow-login
	opkg install luci-app-ttyd
	opkg install mc-skins
	rm /etc/config/atcommands.user
	rm /etc/config/atinout
	rm /etc/config/ttyd
	cd /etc/config/
	wget https://raw.githubusercontent.com/$GITUSER/$GITREPO/$GITTREE/etc/config/atcommands.user
	wget https://raw.githubusercontent.com/$GITUSER/$GITREPO/$GITTREE/etc/config/ttyd
	wget https://raw.githubusercontent.com/$GITUSER/$GITREPO/$GITTREE/etc/config/atinout
	cd /
	service uhttpd enable
	service dropbear enable
	service uhttpd start
	service dropbear start
	echo -e "\e[92m"
    echo "Set your root password:"
    echo -e "\e[0m"
	set_root_passwd
	echo -e "\e[92m"
    echo "Basic packages installed!"
    echo "Visit https://github.com/iamromulan for more!"
    echo -e "\e[0m"
}

ttl_setup() {
  local ttl_file="/etc/firewall.user.ttl"
  local lan_utils_script="/etc/data/lanUtils.sh"
  local combine_function="util_combine_iptable_rules"
  local temp_file="/tmp/temp_firewall_user_ttl"

  overlay_check || return

  while true; do
    if [ ! -f "$ttl_file" ]; then
      echo "Creating $ttl_file..."
      touch "$ttl_file"

      echo "Modifying $combine_function in $lan_utils_script..."

      # Backup the original script
      cp "$lan_utils_script" "${lan_utils_script}.bak"

      # Add the local ttl_firewall_file line if it's not already present
      if ! grep -q "local ttl_firewall_file" "$lan_utils_script"; then
        sed -i '/local tcpmss_firewall_filev6/a \  local ttl_firewall_file=/etc/firewall.user.ttl' "$lan_utils_script"
      fi

      # Add the condition to include the ttl_firewall_file if it's not already present
      if (! grep -q "if \[ -f \"\$ttl_firewall_file\" \]; then" "$lan_utils_script"); then
        sed -i '/if \[ -f "\$tcpmss_firewall_filev6" \]; then/i \  if [ -f "\$ttl_firewall_file" ]; then\n    cat \$ttl_firewall_file >> \$firewall_file\n  fi' "$lan_utils_script"
      fi
    fi

    if [ ! -s "$ttl_file" ]; then
      echo -e "\e[31mTTL is not enabled\e[0m"
    else
      ipv4_ttl=$(grep 'iptables -t mangle -A POSTROUTING' "$ttl_file" | awk '{for(i=1;i<=NF;i++){if($i=="--ttl-set"){print $(i+1)}}}')
      ipv6_ttl=$(grep 'ip6tables -t mangle -A POSTROUTING' "$ttl_file" | awk '{for(i=1;i<=NF;i++){if($i=="--hl-set"){print $(i+1)}}}')
      echo -e "\e[32mCurrent IPv4 TTL: $ipv4_ttl\e[0m"
      echo -e "\e[32mCurrent IPv6 TTL: $ipv6_ttl\e[0m"
    fi

    echo -e "\e[32mWould you like to edit the TTL settings?\e[0m"
    echo -e "\e[32mTTL Value will be set without needing a reboot \e[0m"
    echo -e "\e[33mType yes or exit:\e[0m" && read -r response

    if [ "$response" = "exit" ]; then
      echo "Exiting..."
      break
    elif [ "$response" = "yes" ]; then
      echo -e "\e[32mType 0 to disable TTL\e[0m"
      echo -e "\e[33mEnter the TTL value (number only):\e[0m" && read -r ttl_value
      if ! [[ "$ttl_value" =~ ^[0-9]+$ ]]; then
        echo "Invalid input, please enter a number."
      else
        # Clear existing TTL rules
        echo "Clearing existing TTL rules..."
        iptables -t mangle -D POSTROUTING -o rmnet+ -j TTL --ttl-set "$ipv4_ttl"
        ip6tables -t mangle -D POSTROUTING -o rmnet+ -j HL --hl-set "$ipv6_ttl"

        if [ "$ttl_value" -eq 0 ]; then
          echo "Disabling TTL..."
          > "$ttl_file"
        else
          echo "Setting TTL to $ttl_value..."
          echo "iptables -t mangle -A POSTROUTING -o rmnet+ -j TTL --ttl-set $ttl_value" > "$ttl_file"
          echo "ip6tables -t mangle -A POSTROUTING -o rmnet+ -j HL --hl-set $ttl_value" >> "$ttl_file"
          iptables -t mangle -A POSTROUTING -o rmnet+ -j TTL --ttl-set $ttl_value
          ip6tables -t mangle -A POSTROUTING -o rmnet+ -j HL --hl-set $ttl_value
        fi
      fi
    fi
  done
}

set_root_passwd() {
    passwd
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
    echo -e "\e[1;31mInstalling Tailscale from opkg...\e[0m"
    opkg install tailscale
    if [ $? -ne 0 ]; then
        echo -e "\e[1;31mFailed to install Tailscale via opkg.\e[0m"
        return 1
    fi

    echo -e "\e[1;32mTailscale has been installed via opkg.\e[0m"
    echo -e "\e[1;32mUpdating to the latest Tailscale version...\e[0m"
	
	# Stop Running Service
	service tailscale stop

    # Define variables for the download
    TAILSCALE_URL="https://pkgs.tailscale.com/stable/tailscale_1.74.1_arm64.tgz"
    TAILSCALE_TGZ="/tmp/tailscale_1.74.1_arm64.tgz"
    TAILSCALE_TMP_DIR="/tmp/tailscale_update"

    # Download the latest Tailscale package
    echo -e "\e[1;32mDownloading latest Tailscale package...\e[0m"
    wget -O "$TAILSCALE_TGZ" "$TAILSCALE_URL"
    if [ $? -ne 0 ]; then
        echo -e "\e[1;31mFailed to download Tailscale package. Please check your internet connection.\e[0m"
        rm -f "$TAILSCALE_TGZ"
        return 1
    fi

    # Extract the package
    echo -e "\e[1;32mExtracting Tailscale package...\e[0m"
    mkdir -p "$TAILSCALE_TMP_DIR"
    tar -xzf "$TAILSCALE_TGZ" -C "$TAILSCALE_TMP_DIR"
    if [ $? -ne 0 ]; then
        echo -e "\e[1;31mFailed to extract Tailscale package.\e[0m"
        rm -f "$TAILSCALE_TGZ"
        rm -rf "$TAILSCALE_TMP_DIR"
        return 1
    fi

    # Replace the binaries with force option
    echo -e "\e[1;32mUpdating Tailscale binaries...\e[0m"
    cp -f "$TAILSCALE_TMP_DIR/tailscale_1.74.1_arm64/tailscale" /usr/sbin/
    cp -f "$TAILSCALE_TMP_DIR/tailscale_1.74.1_arm64/tailscaled" /usr/sbin/
    if [ $? -ne 0 ]; then
        echo -e "\e[1;31mFailed to copy new Tailscale binaries.\e[0m"
        rm -f "$TAILSCALE_TGZ"
        rm -rf "$TAILSCALE_TMP_DIR"
        return 1
    fi

    # Set the correct permissions
    chmod +x /usr/sbin/tailscale /usr/sbin/tailscaled

    # Clean up temporary files
    rm -f "$TAILSCALE_TGZ"
    rm -rf "$TAILSCALE_TMP_DIR"

    # Start Tailscale service if available
    service tailscale start
    echo -e "\e[1;32mTailscale version 1.74.1 installed\e[0m"
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
        1) send_at_commands_using_atcmd ;;
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
