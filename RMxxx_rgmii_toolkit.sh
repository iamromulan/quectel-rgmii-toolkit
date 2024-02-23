#!/bin/sh

# Define toolkit paths
GITTREE="development"
TMP_DIR="/tmp"
USRDATA_DIR="/usrdata"
SOCAT_AT_DIR="/usrdata/socat-at-bridge"
SOCAT_AT_SYSD_DIR="/usrdata/socat-at-bridge/systemd_units"
SOCAT_AT_SMD7_SYSD_DIR="/usrdata/socat-at-bridge/smd7_systemd_units"
SIMPLE_ADMIN_DIR="/usrdata/simpleadmin"
SIMPLE_FIREWALL_DIR="/usrdata/simplefirewall"
SIMPLE_FIREWALL_SCRIPT="$SIMPLE_FIREWALL_DIR/simplefirewall.sh"
SIMPLE_FIREWALL_SYSTEMD_DIR="$SIMPLE_FIREWALL_DIR/systemd"
SIMPLE_FIREWALL_SERVICE="/lib/systemd/system/simplefirewall.service"
GITHUB_URL="https://github.com/iamromulan/quectel-rgmii-toolkit/archive/refs/heads/$GITTREE.zip"
GITHUB_SIMPADMIN_FULL_URL="https://github.com/iamromulan/quectel-rgmii-toolkit/archive/refs/heads/simpleadminfullatcmds.zip"
GITHUB_SIMPADMIN_TTL_URL="https://github.com/iamromulan/quectel-rgmii-toolkit/archive/refs/heads/simpleadminttlonly.zip"
GITHUB_SIMPADMIN_TEST_URL="https://github.com/iamromulan/quectel-rgmii-toolkit/archive/refs/heads/simpleadmintest.zip"
TAILSCALE_DIR="/usrdata/tailscale/"
TAILSCALE_SYSD_DIR="/usrdata/tailscale/systemd"
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

# Basic AT commands without socat bridge for fast responce commands only
start_listening() {
    cat "$DEVICE_FILE" > /tmp/device_readout &
    CAT_PID=$!
}

send_at_command() {
    echo "Enter AT command (or type 'exit' to quit): "
    echo "Type 'install' to simply type atcmd in shell from now on"
    read at_command
    if [ "$at_command" = "exit" ]; then
        return 1
    fi
    
    if [ "$at_command" = "install" ]; then
        wget -P /usrdata https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/atcmd
	chmod +x /usrdata/atcmd
 	remount_rw
 	ln -sf /usrdata/atcmd /sbin
  	remount_ro
   	echo "Installed. Type atcmd from adb shell or ssh to start an AT Command session"
    fi
    echo -e "${at_command}\r" > "$DEVICE_FILE"
}

wait_for_response() {
    local start_time=$(date +%s)
    local current_time
    local elapsed_time

    echo "Command sent, waiting for response..."
    while true; do
        if grep -qe "OK" -e "ERROR" /tmp/device_readout; then
            echo "Response received:"
            cat /tmp/device_readout
            return 0
        fi
        current_time=$(date +%s)
        elapsed_time=$((current_time - start_time))
        if [ "$elapsed_time" -ge "$TIMEOUT" ]; then
            echo "Error: Response timed out."
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
        echo "Error: Device $DEVICE_FILE does not exist or is not a character special file."
    fi
}

# Check if Simple Admin is installed
is_simple_admin_installed() {
    [ -d "$SIMPLE_ADMIN_DIR" ] && return 0 || return 1
}

# Function to install/update AT Socat Bridge
install_update_at_socat() {
    remount_rw
    mkdir "$SOCAT_AT_DIR"
    cd "$SOCAT_AT_DIR"
    mkdir $SOCAT_AT_SYSD_DIR
    mkdir $SOCAT_AT_SMD7_SYSD_DIR
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/socat-armel-static
    cd $SOCAT_AT_SYSD_DIR
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/systemd_units/socat-smd11.service
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/systemd_units/socat-smd11-from-ttyIN.service
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/systemd_units/socat-smd11-to-ttyIN.service
    cd $SOCAT_AT_SMD7_SYSD_DIR
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/smd7_systemd_units/socat-smd7-from-ttyIN.service
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/smd7_systemd_units/socat-smd7-to-ttyIN.service
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/smd7_systemd_units/socat-smd7.service

    # Set execute permissions
    chmod +x "$SOCAT_AT_DIR"/socat-armel-static

    # User prompt for selecting device
    echo "Which device should Simpleadmin use?"
    echo "This will create virtual tty ports (serial ports) that will use either smd11 or smd7"
    echo "1) Use smd11 (default)"
    echo "2) Use smd7 (use this if another application is using smd11 already)"
    read -p "Enter your choice (1 or 2): " device_choice

    # Stop and disable existing services before installing new ones
    echo -e "\033[0;32mThese errors are OK, script tries to remove all first in case you are updating\033[0m"
    systemctl stop at-telnet-daemon
    systemctl disable at-telnet-daemon
    systemctl stop socat-smd11
    systemctl stop socat-smd11-to-ttyIN
    systemctl stop socat-smd11-from-ttyIN
    systemctl stop socat-smd7
    systemctl stop socat-smd7-to-ttyIN
    systemctl stop socat-smd7-from-ttyIN
    rm /lib/systemd/system/at-telnet-daemon.service
    rm /lib/systemd/system/socat-smd11.service
    rm /lib/systemd/system/socat-smd11-to-ttyIN.service
    rm /lib/systemd/system/socat-smd11-from-ttyIN.service
    rm /lib/systemd/system/socat-smd7.service
    rm /lib/systemd/system/socat-smd7-to-ttyIN.service
    rm /lib/systemd/system/socat-smd7-from-ttyIN.service
    systemctl daemon-reload
    echo -e "\033[0;32mThese errors are OK, script tries to remove all first in case you are updating\033[0m"
	
    # Depending on the choice, copy the respective systemd unit files
    case $device_choice in
        2)
            cp -f $SOCAT_AT_SMD7_SYSD_DIR/*.service /lib/systemd/system
	    ln -sf /lib/systemd/system/socat-smd7.service /lib/systemd/system/multi-user.target.wants/
	    ln -sf /lib/systemd/system/socat-smd7-to-ttyIN.service /lib/systemd/system/multi-user.target.wants/
	    ln -sf /lib/systemd/system/socat-smd7-from-ttyIN.service /lib/systemd/system/multi-user.target.wants/
	    systemctl daemon-reload
	    systemctl start socat-smd7
	    sleep 2s
	    systemctl start socat-smd7-to-ttyIN
	    systemctl start socat-smd7-from-ttyIN
   	    remount_ro
	    cd /
            ;;
        1)
            cp -f $SOCAT_AT_SYSD_DIR/*.service /lib/systemd/system
	    ln -sf /lib/systemd/system/socat-smd11.service /lib/systemd/system/multi-user.target.wants/
	    ln -sf /lib/systemd/system/socat-smd11-to-ttyIN.service /lib/systemd/system/multi-user.target.wants/
	    ln -sf /lib/systemd/system/socat-smd11-from-ttyIN.service /lib/systemd/system/multi-user.target.wants/
	    systemctl daemon-reload
	    systemctl start socat-smd11
	    sleep 2s
	    systemctl start socat-smd11-to-ttyIN
	    systemctl start socat-smd11-from-ttyIN
   	    remount_ro
	    cd /
            ;;
    esac
    
}

# Function to install Simple Firewall
install_simple_firewall() {
    systemctl stop simplefirewall
    systemctl stop ttl-override
    echo -e "\033[0;32mInstalling/Updating Simple Firewall...\033[0m"
    mount -o remount,rw /
    mkdir -p "$SIMPLE_FIREWALL_DIR"
    mkdir -p "$SIMPLE_FIREWALL_SYSTEMD_DIR"
    wget -O "$SIMPLE_FIREWALL_DIR/simplefirewall.sh" https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/$GITTREE/simplefirewall/simplefirewall.sh
    wget -O "$SIMPLE_FIREWALL_DIR/ttl-override" https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/$GITTREE/simplefirewall/ttl-override
    wget -O "$SIMPLE_FIREWALL_DIR/ttlvalue" https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/$GITTREE/simplefirewall/ttlvalue
    chmod +x "$SIMPLE_FIREWALL_DIR/simplefirewall.sh"
    chmod +x "$SIMPLE_FIREWALL_DIR/ttl-override"	
    wget -O "$SIMPLE_FIREWALL_SYSTEMD_DIR/simplefirewall.service" https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/$GITTREE/simplefirewall/systemd/simplefirewall.service
    wget -O "$SIMPLE_FIREWALL_SYSTEMD_DIR/ttl-override.service" https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/$GITTREE/simplefirewall/systemd/ttl-override.service
    cp -f $SIMPLE_FIREWALL_SYSTEMD_DIR/* /lib/systemd/system
    ln -sf "/lib/systemd/system/simplefirewall.service" "/lib/systemd/system/multi-user.target.wants/"
    ln -sf "/lib/systemd/system/ttl-override.service" "/lib/systemd/system/multi-user.target.wants/"
    systemctl daemon-reload
    systemctl start simplefirewall
    systemctl start ttl-override
    remount_ro
    echo -e "\033[0;32mSimple Firewall installation/update complete.\033[0m"
}

configure_simple_firewall() {
    if [ ! -f "$SIMPLE_FIREWALL_SCRIPT" ]; then
        echo "Simple Firewall script not found."
        return
    fi

    echo "Configuring Simple Firewall:"
    echo "1) Configure incoming port block"
    echo "2) Configure TTL"
    read -p "Enter your choice (1-2): " menu_choice

    case $menu_choice in
    1)
        # Original ports configuration code with exit option
        current_ports_line=$(grep '^PORTS=' "$SIMPLE_FIREWALL_SCRIPT")
        ports=$(echo "$current_ports_line" | cut -d'=' -f2 | tr -d '()' | tr ' ' '\n' | grep -o '[0-9]\+')
        echo "Current configured ports:"
        echo "$ports" | awk '{print NR") "$0}'

        while true; do
            echo "Enter a port number to add/remove, or type 'done' or 'exit' to finish:"
            read port
            if [ "$port" = "done" ] || [ "$port" = "exit" ]; then
                if [ "$port" = "exit" ]; then
                    echo "Exiting without making changes..."
                    return
                fi
                break
            elif ! echo "$port" | grep -qE '^[0-9]+$'; then
                echo "Invalid input: Please enter a numeric value."
            elif echo "$ports" | grep -q "^$port\$"; then
                ports=$(echo "$ports" | grep -v "^$port\$")
                echo "Port $port removed."
            else
                ports=$(echo "$ports"; echo "$port" | grep -o '[0-9]\+')
                echo "Port $port added."
            fi
        done

        if [ "$port" != "exit" ]; then
            new_ports_line="PORTS=($(echo "$ports" | tr '\n' ' '))"
            sed -i "s/$current_ports_line/$new_ports_line/" "$SIMPLE_FIREWALL_SCRIPT"
        fi
        ;;
    2)
        # TTL configuration code
        ttl_value=$(cat /usrdata/simplefirewall/ttlvalue)
        if [ "$ttl_value" -eq 0 ]; then
            echo "TTL is not set."
        else
            echo "TTL value is set to $ttl_value."
        fi

        echo "Type 'exit' to cancel."
        read -p "What do you want the TTL value to be: " new_ttl_value
        if [ "$new_ttl_value" = "exit" ]; then
            echo "Exiting TTL configuration..."
            return
        elif ! echo "$new_ttl_value" | grep -qE '^[0-9]+$'; then
            echo "Invalid input: Please enter a numeric value."
            return
        else
            /usrdata/simplefirewall/ttl-override stop
	    echo "$new_ttl_value" > /usrdata/simplefirewall/ttlvalue
     	    /usrdata/simplefirewall/ttl-override start
            echo -e "\033[0;32mTTL value updated to $new_ttl_value.\033[0m"
        fi
        ;;
    *)
        echo "Invalid choice. Please select either 1 or 2."
        ;;
    esac

    systemctl restart simplefirewall
    echo "Firewall configuration updated."
}

# Function to install/update Simple Admin
install_simple_admin() {
    while true; do
	echo "What version of Simple Admin do you want to install? This will start a webserver on port 8080"
        echo "1) Full Install"
        echo "2) No AT Commands, List only "
        echo "3) TTL Only"
	echo "4) Install Test Build (work in progress/not ready yet)"
        echo "5) Return to Main Menu"
        echo "Select your choice: "
        read choice

        case $choice in
            1)
		install_update_at_socat
		install_simple_firewall
                remount_rw
                cd $TMP_DIR
                wget $GITHUB_SIMPADMIN_FULL_URL -O simpleadminfull.zip
                unzip -o simpleadminfull.zip
                cp -Rf quectel-rgmii-toolkit-simpleadminfull/simpleadmin/ $USRDATA_DIR
                chmod +x $SIMPLE_ADMIN_DIR/scripts/*
                chmod +x $SIMPLE_ADMIN_DIR/www/cgi-bin/*
                cp -f $SIMPLE_ADMIN_DIR/systemd/* /lib/systemd/system
                systemctl daemon-reload
                ln -sf /lib/systemd/system/simpleadmin_httpd.service /lib/systemd/system/multi-user.target.wants/
                ln -sf /lib/systemd/system/simpleadmin_generate_status.service /lib/systemd/system/multi-user.target.wants/
                systemctl start simpleadmin_generate_status
                systemctl start simpleadmin_httpd
                remount_ro
                echo "Cleaning up..."
		rm /tmp/simpleadminfull.zip
		rm -rf /tmp/quectel-rgmii-toolkit-simpleadminfull/
                break
                ;;
            2)
		install_update_at_socat
		install_simple_firewall
                remount_rw
                cd $TMP_DIR
                wget $GITHUB_SIMPADMIN_NOCMD_URL -O simpleadminnoatcmds.zip
                unzip -o simpleadminnoatcmds.zip
                cp -Rf quectel-rgmii-toolkit-simpleadminnoatcmds/simpleadmin/ $USRDATA_DIR
                chmod +x $SIMPLE_ADMIN_DIR/scripts/*
                chmod +x $SIMPLE_ADMIN_DIR/www/cgi-bin/*
                cp -f $SIMPLE_ADMIN_DIR/systemd/* /lib/systemd/system
                systemctl daemon-reload
                ln -sf /lib/systemd/system/simpleadmin_httpd.service /lib/systemd/system/multi-user.target.wants/
                ln -sf /lib/systemd/system/simpleadmin_generate_status.service /lib/systemd/system/multi-user.target.wants/
                systemctl start simpleadmin_generate_status
                systemctl start simpleadmin_httpd
                remount_ro
		echo "Cleaning up..."
		rm /tmp/simpleadminnoatcmds.zip
		rm -rf /tmp/quectel-rgmii-toolkit-simpleadminnoatcmds/
                break
                ;;
            3)
		install_simple_firewall
                remount_rw
                cd $TMP_DIR
                wget $GITHUB_SIMPADMIN_TTL_URL -O simpleadminttlonly.zip
                unzip -o simpleadminttlonly.zip
                cp -Rf quectel-rgmii-toolkit-simpleadminttlonly/simpleadmin/ $USRDATA_DIR
		chmod +x $SIMPLE_ADMIN_DIR/www/cgi-bin/*
                cp -f $SIMPLE_ADMIN_DIR/systemd/* /lib/systemd/system
                systemctl daemon-reload
                ln -sf /lib/systemd/system/simpleadmin_httpd.service /lib/systemd/system/multi-user.target.wants/
                systemctl start simpleadmin_httpd
                remount_ro
		echo "Cleaning up..."
		rm /tmp/simpleadminttlonly.zip
		rm -rf /tmp/quectel-rgmii-toolkit-simpleadminttlonly/
                break
                ;;
            4)
		install_update_at_socat
		install_simple_firewall
                remount_rw
                cd $TMP_DIR
                wget $GITHUB_SIMPADMIN_TEST_URL -O simpleadmintest.zip
                unzip -o simpleadmintest.zip
                cp -Rf quectel-rgmii-toolkit-simpleadmintest/simpleadmin/ $USRDATA_DIR
                chmod +x $SIMPLE_ADMIN_DIR/scripts/*
                chmod +x $SIMPLE_ADMIN_DIR/www/cgi-bin/*
                cp -f $SIMPLE_ADMIN_DIR/systemd/* /lib/systemd/system
                systemctl daemon-reload
                ln -sf /lib/systemd/system/simpleadmin_httpd.service /lib/systemd/system/multi-user.target.wants/
                ln -sf /lib/systemd/system/simpleadmin_generate_status.service /lib/systemd/system/multi-user.target.wants/
                systemctl start simpleadmin_generate_status
                systemctl start simpleadmin_httpd
                remount_ro
                break
                ;;
	    5)
                echo "Returning to main menu..."
                break
                ;;
            *)
                echo "Invalid choice. Please try again."
                ;;
        esac
    done
}

# Function to Uninstall Simpleadmin and dependencies
uninstall_simpleadmin_components() {
    echo "Starting the uninstallation process for Simpleadmin components."
    echo "Note: Uninstalling certain components may affect the functionality of others."
    remount_rw

    # Uninstall Simple Firewall
    echo "Do you want to uninstall Simplefirewall?"
    echo "If you do, the TTL part of simpleadmin will no longer work."
    echo "1) Yes"
    echo "2) No"
    read -p "Enter your choice (1 or 2): " choice_simplefirewall
    if [ "$choice_simplefirewall" -eq 1 ]; then
        echo "Uninstalling Simplefirewall..."
        systemctl stop simplefirewall
        systemctl stop ttl-override
        rm -f /lib/systemd/system/simplefirewall.service
        rm -f /lib/systemd/system/ttl-override.service
        systemctl daemon-reload
        rm -rf "$SIMPLE_FIREWALL_DIR"
        echo "Simplefirewall uninstalled."
    fi

    # Uninstall socat-at-bridge
    echo "Do you want to uninstall socat-at-bridge?"
    echo "If you do, AT commands and the stat page will no longer work."
    echo "1) Yes"
    echo "2) No"
    read -p "Enter your choice (1 or 2): " choice_socat_at_bridge
    if [ "$choice_socat_at_bridge" -eq 1 ]; then
        echo "Uninstalling socat-at-bridge..."
	systemctl stop at-telnet-daemon
        systemctl stop socat-smd11
        systemctl stop socat-smd11-to-ttyIN
        systemctl stop socat-smd11-from-ttyIN
        systemctl stop socat-smd7
        systemctl stop socat-smd7-to-ttyIN
        systemctl stop socat-smd7-from-ttyIN
        rm -f /lib/systemd/system/socat-smd11.service
        rm -f /lib/systemd/system/socat-smd11-to-ttyIN.service
        rm -f /lib/systemd/system/socat-smd11-from-ttyIN.service
        rm -f /lib/systemd/system/socat-smd7.service
        rm -f /lib/systemd/system/socat-smd7-to-ttyIN.service
        rm -f /lib/systemd/system/socat-smd7-from-ttyIN.service
	rm -f /lib/systemd/system/at-telnet-daemon.service
        systemctl daemon-reload
        rm -rf "$SOCAT_AT_DIR"
	rm -rf "/usrdata/micropython"
 	rm -rf "/usrdata/at-telnet"
        echo "socat-at-bridge uninstalled."
    fi

    # Uninstall the rest of Simpleadmin
    echo "Do you want to uninstall the rest of Simpleadmin?"
    echo "1) Yes"
    echo "2) No"
    read -p "Enter your choice (1 or 2): " choice_simpleadmin
    if [ "$choice_simpleadmin" -eq 1 ]; then
        echo "Uninstalling the rest of Simpleadmin..."
        systemctl stop simpleadmin_httpd
        systemctl stop simpleadmin_generate_status
        rm -f /lib/systemd/system/simpleadmin_httpd.service
        rm -f /lib/systemd/system/simpleadmin_generate_status.service
        systemctl daemon-reload
        rm -rf "$SIMPLE_ADMIN_DIR"
        echo "The rest of Simpleadmin uninstalled."
	remount_ro
    fi

    echo "Uninstallation process completed."
}

# Function for Tailscale Submenu
tailscale_menu() {
    while true; do
        echo "Tailscale Menu"
        echo "1) Install/Update/Remove Tailscale"
        echo "2) Configure Tailscale"
        echo "3) Return to Main Menu"
        read -p "Enter your choice: " tailscale_choice

        case $tailscale_choice in
            1) install_update_remove_tailscale;;
            2) configure_tailscale;;
            3) break;;
            *) echo "Invalid option";;
        esac
    done
}

# Function to install, update, or remove Tailscale
install_update_remove_tailscale() {
    if [ -d "$TAILSCALE_DIR" ]; then
        echo "Tailscale is already installed."
        echo "1) Update Tailscale"
        echo "2) Remove Tailscale"
        read -p "Enter your choice: " tailscale_update_remove_choice

        case $tailscale_update_remove_choice in
            1) 
		echo "Updating Tailscale..."
		/usrdata/tailscale/tailscale update			
                ;;
            2) 
                echo "Removing Tailscale..."
		remount_rw
                $TAILSCALE_DIR/tailscale down
                $TAILSCALE_DIR/tailscale logout
                systemctl stop tailscaled
                rm -f /lib/systemd/system/tailscaled.service
                systemctl daemon-reload
                rm -rf $TAILSCALE_DIR
                remount_ro
                echo "Tailscale removed successfully."
                ;;
            *) 
                echo "Invalid option";;
        esac
    else
        echo "Installing Tailscale..."
        remount_rw
	echo "Creating /usrdata/tailscale/"
	mkdir $TAILSCALE_DIR
	mkdir $TAILSCALE_SYSD_DIR
        cd $TAILSCALE_DIR
	echo "Downloading binary: /usrdata/tailscale/tailscaled"
        wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/tailscale/tailscaled
	echo "Downloading binary: /usrdata/tailscale/tailscale"
	wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/tailscale/tailscale
    	echo "Downloading systemd files..."
     	cd $TAILSCALE_SYSD_DIR
      	wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/tailscale/systemd/tailscaled.service
       	wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/tailscale/systemd/tailscaled.defaults
	sleep 2s
	echo "Setting Permissions..."
        chmod +x /usrdata/tailscale/tailscaled
        chmod +x /usrdata/tailscale/tailscale
	echo "Copy systemd units..."
        cp -f /usrdata/tailscale/systemd/* /lib/systemd/system
	ln -sf /lib/systemd/system/tailscaled.service /lib/systemd/system/multi-user.target.wants/
        systemctl daemon-reload
	echo "Starting Tailscaled..."
        systemctl start tailscaled
	cd /
        remount_ro
        echo "Tailscale installed successfully."
    fi
}

# Function to Configure Tailscale
configure_tailscale() {
    while true; do
    echo "Configure Tailscale"
    echo "1) Enable Tailscale Web UI at http://192.168.225.1:8088 (Gateway on port 8088)"
    echo "2) Disable Tailscale Web UI"
    echo "3) Connect to Tailnet"
    echo "4) Connect to Tailnet with SSH ON"
    echo "5) Reconnect to Tailnet with SSH OFF"
    echo "6) Disconnect from Tailnet (reconnects at reboot)"
    echo "7) Logout from tailscale account"
    echo "8) Return to Tailscale Menu"
    read -p "Enter your choice: " config_choice

        case $config_choice in
        1)
	remount_rw
	cd /lib/systemd/system/
	wget -O tailscale-webui.service https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/tailscale/systemd/tailscale-webui.service
  	wget -O tailscale-webui-trigger.service https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/tailscale/systemd/tailscale-webui-trigger.service
     	ln -sf /lib/systemd/system/tailscale-webui-trigger.service /lib/systemd/system/multi-user.target.wants/
     	systemctl daemon-reload
       	echo "Tailscale Web UI Enabled"
	echo "Starting Web UI..." 
     	systemctl start tailscale-webui
       	echo "Web UI started!"
     	remount_ro
	;;
	2) 
	remount_rw
  	systemctl stop tailscale-webui
    	systemctl disable tailscale-webui-trigger
  	rm /lib/systemd/system/multi-user.target.wants/tailscale-webui.service
    	rm /lib/systemd/system/multi-user.target.wants/tailscale-webui-trigger.service
    	rm /lib/systemd/system/tailscale-webui.service
      	rm /lib/systemd/system/tailscale-webui-trigger.service
     	systemctl daemon-reload
       	echo "Tailscale Web UI Stopped and Disabled"
     	remount_ro
	;;
	3) $TAILSCALE_DIR/tailscale up --accept-dns=false --reset;;
        4) $TAILSCALE_DIR/tailscale up --ssh --accept-dns=false --reset;;
	5) $TAILSCALE_DIR/tailscale up --accept-dns=false --reset;;
     	6) $TAILSCALE_DIR/tailscale down;;
        7) $TAILSCALE_DIR/tailscale logout;;
        8) break;;
        *) echo "Invalid option";;
        esac
    done
}

# Function to manage Daily Reboot Timer
manage_reboot_timer() {
    # Remount root filesystem as read-write
    mount -o remount,rw /

    # Check if the rebootmodem service, timer, or trigger already exists
    if [ -f /lib/systemd/system/rebootmodem.service ] || [ -f /lib/systemd/system/rebootmodem.timer ] || [ -f /lib/systemd/system/rebootmodem-trigger.service ]; then
        echo "The rebootmodem service/timer/trigger is already installed."
        echo "1) Change"
        echo "2) Remove"
        read -p "Enter your choice (1 for Change, 2 for Remove): " reboot_choice

        case $reboot_choice in
            2)
                # Stop and disable timer and trigger service by removing symlinks
                systemctl stop rebootmodem.timer
                systemctl stop rebootmodem-trigger.service

                # Remove symbolic links and files
                rm -f /lib/systemd/system/multi-user.target.wants/rebootmodem-trigger.service
                rm -f /lib/systemd/system/rebootmodem.service
                rm -f /lib/systemd/system/rebootmodem.timer
                rm -f /lib/systemd/system/rebootmodem-trigger.service
                rm -f "$USRDATA_DIR/reboot_modem.sh"

                # Reload systemd to apply changes
                systemctl daemon-reload

                echo "Rebootmodem service, timer, trigger, and script removed successfully."
                ;;
            1)
                printf "Enter the new time for daily reboot (24-hour format in Coordinated Universal Time, HH:MM): "
                read new_time

                # Validate the new time format using grep
                if ! echo "$new_time" | grep -qE '^([01]?[0-9]|2[0-3]):[0-5][0-9]$'; then
                    echo "Invalid time format. Exiting."
                    exit 1
                else
                    # Remove old symlinks and script
                    rm -f /lib/systemd/system/multi-user.target.wants/rebootmodem-trigger.service
                    rm -f "$USRDATA_DIR/reboot_modem.sh"

                    # Set the user time to the new time and recreate the service, timer, trigger, and script
                    user_time=$new_time
                    create_service_and_timer
                fi
                ;;
            *)
                echo "Invalid choice. Exiting."
                exit 1
                ;;
        esac
    else
        printf "Enter the time for daily reboot (24-hour format in UTC, HH:MM): "
        read user_time

        # Validate the time format using grep
        if ! echo "$user_time" | grep -qE '^([01]?[0-9]|2[0-3]):[0-5][0-9]$'; then
            echo "Invalid time format. Exiting."
            exit 1
        else
            create_service_and_timer
        fi
    fi

    # Remount root filesystem as read-only
    mount -o remount,ro /
}

# Function to create systemd service and timer files with the user-specified time for the reboot timer
create_service_and_timer() {
    remount_rw
    # Define the path for the modem reboot script
    MODEM_REBOOT_SCRIPT="$USRDATA_DIR/reboot_modem.sh"

    # Create the modem reboot script
    echo "#!/bin/sh
/bin/echo -e 'AT+CFUN=1,1 \r' > /dev/smd7" > "$MODEM_REBOOT_SCRIPT"

    # Make the script executable
    chmod +x "$MODEM_REBOOT_SCRIPT"

    # Create the systemd service file for reboot
    echo "[Unit]
Description=Reboot Modem Daily

[Service]
Type=oneshot
ExecStart=/bin/sh /usrdata/reboot_modem.sh
Restart=no
RemainAfterExit=no" > /lib/systemd/system/rebootmodem.service

    # Create the systemd timer file with the user-specified time
    echo "[Unit]
Description=Starts rebootmodem.service daily at the specified time

[Timer]
OnCalendar=*-*-* $user_time:00
Persistent=false" > /lib/systemd/system/rebootmodem.timer

    # Create a trigger service that starts the timer at boot
    echo "[Unit]
Description=Trigger the rebootmodem timer at boot

[Service]
Type=oneshot
ExecStart=/bin/systemctl start rebootmodem.timer
RemainAfterExit=yes" > /lib/systemd/system/rebootmodem-trigger.service

    # Create symbolic links for the trigger service in the wanted directory
    ln -sf /lib/systemd/system/rebootmodem-trigger.service /lib/systemd/system/multi-user.target.wants/

    # Reload systemd to recognize the new timer and trigger service
    systemctl daemon-reload
    sleep 2s

    # Start the trigger service, which will start the timer
    systemctl start rebootmodem-trigger.service
    remount_ro

    # Confirmation
    echo "Rebootmodem-trigger service created and started successfully."
    echo "Reboot schedule set successfully. The modem will reboot daily at $user_time UTC."
}

manage_cfun_fix() {
    cfun_service_path="/lib/systemd/system/cfunfix.service"
    cfun_fix_script="/usrdata/cfun_fix.sh"

    mount -o remount,rw /

    if [ -f "$cfun_service_path" ]; then
        echo "The CFUN fix is already installed. Do you want to remove it?"
        echo "1) Yes"
        echo "2) No"
        read -p "Enter your choice: " choice

        if [ "$choice" = "1" ]; then
            echo "Removing CFUN fix..."
            systemctl stop cfunfix.service
            rm -f /lib/systemd/system/multi-user.target.wants/cfunfix.service
            rm -f "$cfun_service_path"
            rm -f "$cfun_fix_script"
            systemctl daemon-reload
            echo "CFUN fix has been removed."
        else
            echo "Returning to main menu..."
        fi
    else
        echo "Installing CFUN fix..."

        # Create the CFUN fix script
        echo "#!/bin/sh
/bin/echo -e 'AT+CFUN=1 \r' > /dev/smd7" > "$cfun_fix_script"
        chmod +x "$cfun_fix_script"

        # Create the systemd service file to execute the CFUN fix script at boot
        echo "[Unit]
Description=CFUN Fix Service
After=network.target

[Service]
Type=oneshot
ExecStart=$cfun_fix_script
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target" > "$cfun_service_path"

        ln -sf "$cfun_service_path" "/lib/systemd/system/multi-user.target.wants/"
	systemctl daemon-reload
 	mount -o remount,ro /
        echo "CFUN fix has been installed and will execute at every boot."
    fi
}

# Main menu
while true; do
    echo "Welcome to iamromulan's RGMII Toolkit script for Quectel RMxxx Series modems!"
    echo "Select an option:"
    echo "1) Send AT Commands"
    echo "2) Install/Update/Uninstall Simple Admin"
    echo "3) Simple Firewall Management"
    echo "4) Tailscale Management"
    echo "5) Install/Change or remove Daily Reboot Timer"
    echo "6) Install/Uninstall CFUN 0 Fix"
    echo "7) Install Entware/OPKG (BETA/Advanced)"
    echo "8) Exit"
    read -p "Enter your choice: " choice

    case $choice in
        1)
            send_at_commands
            ;;
        2)
            if is_simple_admin_installed; then
                echo "Simple Admin is already installed. It must be removed first"
                echo "1) Remove"
                echo "2) Return to main menu"
                read -p "Enter your choice: " simple_admin_choice
                case $simple_admin_choice in
                    1) uninstall_simpleadmin_components;;
                    2) break;;
                    *) echo "Invalid option";;
                esac
            else
                echo "Installing Simple Admin..."
                install_simple_admin
            fi
            ;;
	3)
	    configure_simple_firewall
            ;;
        
        4)  
	    tailscale_menu
	    ;;
	5)
            manage_reboot_timer
            ;;
	6)
            manage_cfun_fix
            ;;	    
        7) 
	    echo "Installing Entware/OPKG"
     	    wget -O- https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/installentware.sh | sh
     	    break
            ;;
	8) 
	    echo "Goodbye!"
     	    break
            ;;    
        *)
            echo "Invalid option"
            ;;
    esac
done
