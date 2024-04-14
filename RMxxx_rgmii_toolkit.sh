#!/bin/sh

# Define toolkit paths
GITUSER="iamromulan"
GITTREE="development"
GITMAINTREE="main"
GITDEVTREE="development"
TMP_DIR="/tmp"
USRDATA_DIR="/usrdata"
SOCAT_AT_DIR="/usrdata/socat-at-bridge"
SOCAT_AT_SYSD_DIR="/usrdata/socat-at-bridge/systemd_units"
SIMPLE_ADMIN_DIR="/usrdata/simpleadmin"
SIMPLE_FIREWALL_DIR="/usrdata/simplefirewall"
SIMPLE_FIREWALL_SCRIPT="$SIMPLE_FIREWALL_DIR/simplefirewall.sh"
SIMPLE_FIREWALL_SYSTEMD_DIR="$SIMPLE_FIREWALL_DIR/systemd"
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
	    echo -e "\e[1;32mIf the responce takes longer than a second or 2 to respond this will not work\e[0m"  # Green
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

# Check for existing Entware/opkg installation, install if not installed
ensure_entware_installed() {
	remount_rw
    if [ ! -f "/opt/bin/opkg" ]; then
        echo -e "\e[1;32mInstalling Entware/OPKG\e[0m"
        cd /tmp && wget -O installentware.sh "https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/installentware.sh" && chmod +x installentware.sh && ./installentware.sh
        if [ "$?" -ne 0 ]; then
            echo -e "\e[1;31mEntware/OPKG installation failed. Please check your internet connection or the repository URL.\e[0m"
            exit 1
        fi
        cd /
    else
        echo -e "\e[1;32mEntware/OPKG is already installed.\e[0m"
        if [ "$(readlink /bin/login)" != "/opt/bin/login" ]; then
            opkg update && opkg install shadow-login shadow-passwd shadow-useradd
            if [ "$?" -ne 0 ]; then
                echo -e "\e[1;31mPackage installation failed. Please check your internet connection and try again.\e[0m"
                exit 1
            fi

            # Replace the login and passwd binaries and set home for root to a writable directory
            rm /opt/etc/shadow
            rm /opt/etc/passwd
            cp /etc/shadow /opt/etc/
            cp /etc/passwd /opt/etc
            mkdir -p /usrdata/root/bin
            touch /usrdata/root/.profile
            echo "# Set PATH for all shells" > /usrdata/root/.profile
            echo "export PATH=/bin:/usr/sbin:/usr/bin:/sbin:/opt/sbin:/opt/bin:/usrdata/root/bin" >> /usrdata/root/.profile
            chmod +x /usrdata/root/.profile
            sed -i '1s|/home/root:/bin/sh|/usrdata/root:/bin/bash|' /opt/etc/passwd
            rm /bin/login /usr/bin/passwd
            ln -sf /opt/bin/login /bin
            ln -sf /opt/bin/passwd /usr/bin/
			ln -sf /opt/bin/useradd /usr/bin/
            echo -e "\e[1;31mPlease set the root password.\e[0m"
            /opt/bin/passwd

            # Install basic and useful utilities
            opkg install mc htop dfc lsof
            ln -sf /opt/bin/mc /bin
            ln -sf /opt/bin/htop /bin
            ln -sf /opt/bin/dfc /bin
            ln -sf /opt/bin/lsof /bin
        fi

        if [ ! -f "/usrdata/root/.profile" ]; then
            opkg update && opkg install shadow-useradd
            mkdir -p /usrdata/root/bin
            touch /usrdata/root/.profile
            echo "# Set PATH for all shells" > /usrdata/root/.profile
            echo "export PATH=/bin:/usr/sbin:/usr/bin:/sbin:/opt/sbin:/opt/bin:/usrdata/root/bin" >> /usrdata/root/.profile
            chmod +x /usrdata/root/.profile
            sed -i '1s|/home/root:/bin/sh|/usrdata/root:/bin/bash|' /opt/etc/passwd
        fi
    fi
	if [ ! -f "/opt/sbin/useradd" ]; then
		echo "useradd does not exist. Installing shadow-useradd..."
		opkg install shadow-useradd
		else
		echo "useradd already exists. Continuing..."
	fi

}

#Uninstall Entware if the Users chooses 
uninstall_entware() {
    echo -e '\033[31mInfo: Starting Entware/OPKG uninstallation...\033[0m'

    # Stop services
    systemctl stop rc.unslung.service
    /opt/etc/init.d/rc.unslung stop
    rm /lib/systemd/system/multi-user.target.wants/rc.unslung.service
    rm /lib/systemd/system/rc.unslung.service
    
    systemctl stop opt.mount
    rm /lib/systemd/system/multi-user.target.wants/start-opt-mount.service
    rm /lib/systemd/system/opt.mount
    rm /lib/systemd/system/start-opt-mount.service

    # Unmount /opt if mounted
    mountpoint -q /opt && umount /opt

    # Remove Entware installation directory
    rm -rf /usrdata/opt
    rm -rf /opt

    # Reload systemctl daemon
    systemctl daemon-reload

    # Optionally, clean up any modifications to /etc/profile or other system files
    # Restore original link to login binary compiled by Quectel
    rm /bin/login
    ln /bin/login.shadow /bin/login

    echo -e '\033[32mInfo: Entware/OPKG has been uninstalled successfully.\033[0m'
}

# function to configure the fetures of simplefirewall
configure_simple_firewall() {
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
        # Original ports configuration code with exit option
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
        ;;
    2)
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
        ;;
    *)
        echo -e "\e[1;31mInvalid choice. Please select either 1 or 2.\e[0m"
        ;;
    esac

    systemctl restart simplefirewall
    echo -e "\e[1;32mFirewall configuration updated.\e[0m"
}

set_simpleadmin_passwd(){
			while true; do
				echo -e "\e[1;31mPlease set your simpleadmin (User: admin) web login password.\e[0m"
				read -s password
				if [ -z "$password" ]; then
					echo -e "\e[1;32mNo password provided.\e[0m"
				else
					mkdir $SIMPLE_ADMIN_DIR > /dev/null 2>&1
					echo -n "admin:" > $SIMPLE_ADMIN_DIR/.htpasswd
					openssl passwd -crypt "$password" >> $SIMPLE_ADMIN_DIR/.htpasswd
					echo -e "\e[1;32mPassword set.\e[0m"
					break
				fi
			done
}

set_root_passwd() {
echo -e "\e[1;31mPlease set the root/console password.\e[0m"
/opt/bin/passwd
}

# Function to install/update Simple Admin
install_simple_admin() {
    while true; do
	echo -e "\e[1;32mWhat version of Simple Admin do you want to install? This will start a webserver on port 80/443 on test build\e[0m"
    echo -e "\e[1;32m1) Stable current version, (Main Branch)\e[0m"
	echo -e "\e[1;31m2) Install Test Build (Development Branch)\e[0m"
	echo -e "\e[0;33m3) Return to Main Menu\e[0m"
 	echo -e "\e[1;32mSelect your choice: \e[0m"
        read choice

        case $choice in
        1)
            echo -e "\e[1;32mYou are using the development toolkit; Use the one from main if you want the stable version right now\e[0m"
            break
			;;
        2)
			ensure_entware_installed
			echo -e "\e[1;31m2) Installing simpleadmin from the development test branch\e[0m"
			mkdir /usrdata/simpleupdates > /dev/null 2>&1
		    mkdir /usrdata/simpleupdates/scripts > /dev/null 2>&1
		    wget -O /usrdata/simpleupdates/scripts/update_socat-at-bridge.sh https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleupdates/scripts/update_socat-at-bridge.sh && chmod +x /usrdata/simpleupdates/scripts/update_socat-at-bridge.sh
		    echo -e "\e[1;32mInstalling/updating dependency: socat-at-bridge\e[0m"
			echo -e "\e[1;32mPlease Wait....\e[0m"
			/usrdata/simpleupdates/scripts/update_socat-at-bridge.sh
			echo -e "\e[1;32m Dependency: socat-at-bridge has been updated/installed.\e[0m"
			sleep 1
		    wget -O /usrdata/simpleupdates/scripts/update_simplefirewall.sh https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleupdates/scripts/update_simplefirewall.sh && chmod +x /usrdata/simpleupdates/scripts/update_simplefirewall.sh
		    echo -e "\e[1;32mInstalling/updating dependency: simplefirewall\e[0m"
			echo -e "\e[1;32mPlease Wait....\e[0m"
			/usrdata/simpleupdates/scripts/update_simplefirewall.sh
			echo -e "\e[1;32m Dependency: simplefirewall has been updated/installed.\e[0m"
			sleep 1
			set_simpleadmin_passwd
		    wget -O /usrdata/simpleupdates/scripts/update_simpeadmin.sh https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleupdates/scripts/update_simpleadmin.sh && chmod +x /usrdata/simpleupdates/scripts/update_simpleadmin.sh
			echo -e "\e[1;32mInstalling/updating: Simpleadmin content\e[0m"
			echo -e "\e[1;32mPlease Wait....\e[0m"
			/usrdata/simpleupdates/scripts/update_simpleadmin.sh
            echo -e "\e[1;32mSimpleadmin content has been updated/installed.\e[0m"
			sleep 1
            break
            ;;
	    3)
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
    echo -e "\e[1;32mStarting the uninstallation process for Simpleadmin components.\e[0m"
    echo -e "\e[1;32mNote: Uninstalling certain components may affect the functionality of others.\e[0m"
    remount_rw

    # Uninstall Simple Firewall
    echo -e "\e[1;32mDo you want to uninstall Simplefirewall?\e[0m"
    echo -e "\e[1;31mIf you do, the TTL part of simpleadmin will no longer work.\e[0m"
    echo -e "\e[1;32m1) Yes\e[0m"
    echo -e "\e[1;31m2) No\e[0m"
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
    echo -e "\e[1;32mDo you want to uninstall socat-at-bridge?\e[0m"
    echo -e "\e[1;31mIf you do, AT commands and the stat page will no longer work. atcmd won't either.\e[0m"
    echo -e "\e[1;32m1) Yes\e[0m"
    echo -e "\e[1;31m2) No\e[0m"
    read -p "Enter your choice (1 or 2): " choice_socat_at_bridge
    if [ "$choice_socat_at_bridge" -eq 1 ]; then
        echo -e "\033[0;32mRemoving installed AT Socat Bridge services...\033[0m"
		systemctl stop at-telnet-daemon > /dev/null 2>&1
		systemctl disable at-telnet-daemon > /dev/null 2>&1
		systemctl stop socat-smd11 > /dev/null 2>&1
		systemctl stop socat-smd11-to-ttyIN > /dev/null 2>&1
		systemctl stop socat-smd11-from-ttyIN > /dev/null 2>&1
		systemctl stop socat-smd7 > /dev/null 2>&1
		systemctl stop socat-smd7-to-ttyIN2 > /dev/null 2>&1
		systemctl stop socat-smd7-to-ttyIN > /dev/null 2>&1
		systemctl stop socat-smd7-from-ttyIN2 > /dev/null 2>&1
		systemctl stop socat-smd7-from-ttyIN > /dev/null 2>&1
		rm /lib/systemd/system/at-telnet-daemon.service > /dev/null 2>&1
		rm /lib/systemd/system/socat-smd11.service > /dev/null 2>&1
		rm /lib/systemd/system/socat-smd11-to-ttyIN.service > /dev/null 2>&1
		rm /lib/systemd/system/socat-smd11-from-ttyIN.service > /dev/null 2>&1
		rm /lib/systemd/system/socat-smd7.service > /dev/null 2>&1
		rm /lib/systemd/system/socat-smd7-to-ttyIN2.service > /dev/null 2>&1
		rm /lib/systemd/system/socat-smd7-to-ttyIN.service > /dev/null 2>&1
		rm /lib/systemd/system/socat-smd7-from-ttyIN.service > /dev/null 2>&1
		rm /lib/systemd/system/socat-smd7-from-ttyIN2.service > /dev/null 2>&1
		systemctl daemon-reload > /dev/null 2>&1
		rm -rf "$SOCAT_AT_DIR" > /dev/null 2>&1
		rm -rf "$SOCAT_AT_DIR" > /dev/null 2>&1
		rm -rf "/usrdata/micropython" > /dev/null 2>&1
		rm -rf "/usrdata/at-telnet" > /dev/null 2>&1
		echo -e "\033[0;32mAT Socat Bridge services removed!...\033[0m"
    fi

	# Uninstall ttyd
    echo -e "\e[1;32mDo you want to uninstall ttyd (simpleadmin console)?\e[0m"
	echo -e "\e[1;31mWarning: Do not uninstall if you are currently using ttyd to do this!!!\e[0m"
    echo -e "\e[1;32m1) Yes\e[0m"
    echo -e "\e[1;31m2) No\e[0m"
    read -p "Enter your choice (1 or 2): " choice_simpleadmin
    if [ "$choice_simpleadmin" -eq 1 ]; then
		echo -e "\e[1;34mUninstalling ttyd...\e[0m"
        systemctl stop ttyd
        rm -rf /usrdata/ttyd
        rm /lib/systemd/system/ttyd.service
        rm /lib/systemd/system/multi-user.target.wants/ttyd.service
        rm /bin/ttyd
        echo -e "\e[1;32mttyd has been uninstalled.\e[0m"
	fi

	echo "Uninstalling the rest of Simpleadmin..."
		
	# Check if Lighttpd service is installed and remove it if present
	if [ -f "/lib/systemd/system/lighttpd.service" ]; then
		echo "Lighttpd detected, uninstalling Lighttpd and its modules..."
		systemctl stop lighttpd
		opkg --force-remove --force-removal-of-dependent-packages remove lighttpd-mod-authn_file lighttpd-mod-auth lighttpd-mod-cgi lighttpd-mod-openssl lighttpd-mod-proxy lighttpd
		rm -rf $LIGHTTPD_DIR
	fi

	systemctl stop simpleadmin_generate_status
	systemctl stop simpleadmin_httpd
	rm -f /lib/systemd/system/simpleadmin_httpd.service
	rm -f /lib/systemd/system/simpleadmin_generate_status.service
	systemctl daemon-reload
	rm -rf "$SIMPLE_ADMIN_DIR"
	echo "The rest of Simpleadmin and Lighttpd (if present) uninstalled."
	remount_ro

    echo "Uninstallation process completed."
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
            1) install_update_tailscale;;
            2) configure_tailscale;;
            3) break;;
            *) echo "Invalid option";;
        esac
    done
}

# Function to install, update, or remove Tailscale
install_update_tailscale() {
echo -e "\e[1;31m2) Installing tailscale from the $GITTREE branch\e[0m"
			mkdir /usrdata/simpleupdates > /dev/null 2>&1
		    mkdir /usrdata/simpleupdates/scripts > /dev/null 2>&1
		    wget -O /usrdata/simpleupdates/scripts/update_tailscale.sh https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleupdates/scripts/update_tailscale.sh && chmod +x /usrdata/simpleupdates/scripts/update_tailscale.sh
		    echo -e "\e[1;32mInstalling/updating: Tailscale\e[0m"
			echo -e "\e[1;32mPlease Wait....\e[0m"
			/usrdata/simpleupdates/scripts/update_tailscale.sh
			echo -e "\e[1;32m Tailscale has been updated/installed.\e[0m"
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
        1)
	remount_rw
	cd /lib/systemd/system/
	wget -O tailscale-webui.service https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/main/tailscale/systemd/tailscale-webui.service
  	wget -O tailscale-webui-trigger.service https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/main/tailscale/systemd/tailscale-webui-trigger.service
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
        echo -e "\e[1;32mThe rebootmodem service/timer/trigger is already installed.\e[0m"
	echo -e "\e[1;32m1) Change\e[0m"  # Green
	echo -e "\e[1;31m2) Remove\e[0m"  # Red
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

                echo -e "\e[1;32mRebootmodem service, timer, trigger, and script removed successfully.\e[0m"
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
                echo -e "\e[1;31mInvalid choice. Exiting.\e[0m"
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
    echo -e "\e[1;32mRebootmodem-trigger service created and started successfully.\e[0m"
    echo -e "\e[1;32mReboot schedule set successfully. The modem will reboot daily at $user_time UTC.\e[0m"
}

manage_cfun_fix() {
    cfun_service_path="/lib/systemd/system/cfunfix.service"
    cfun_fix_script="/usrdata/cfun_fix.sh"

    mount -o remount,rw /

    if [ -f "$cfun_service_path" ]; then
        echo -e "\e[1;32mThe CFUN fix is already installed. Do you want to remove it?\e[0m"  # Green
	echo -e "\e[1;32m1) Yes\e[0m"  # Green
	echo -e "\e[1;31m2) No\e[0m"   # Red
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
        echo -e "\e[1;32mInstalling CFUN fix...\e[0m"

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
        echo -e "\e[1;32mCFUN fix has been installed and will execute at every boot.\e[0m"
    fi
}

install_sshd() {
ensure_entware_installed
echo -e "\e[1;31m2) Installing sshd from the $GITTREE branch\e[0m"
			mkdir /usrdata/simpleupdates > /dev/null 2>&1
		    mkdir /usrdata/simpleupdates/scripts > /dev/null 2>&1
		    wget -O /usrdata/simpleupdates/scripts/update_sshd.sh https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleupdates/scripts/update_sshd.sh && chmod +x /usrdata/simpleupdates/scripts/update_sshd.sh
		    echo -e "\e[1;32mInstalling/updating: SSHd\e[0m"
			echo -e "\e[1;32mPlease Wait....\e[0m"
			/usrdata/simpleupdates/scripts/update_sshd.sh
			echo -e "\e[1;32m SSHd has been updated/installed.\e[0m"	    
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
    echo "Welcome to iamromulan's RGMII Toolkit script for Quectel RMxxx Series modems!"
    echo "Visit https://github.com/iamromulan for more!"
    echo -e "\e[0m"
    echo "Select an option:"
    echo -e "\e[0m"
    echo -e "\e[96m1) Send AT Commands\e[0m" # Cyan
    echo -e "\e[93m2) Install Simple Admin\e[0m" # Yellow
	echo -e "\e[95m3) Set Simpleadmin (admin) password\e[0m" # Light Purple
	echo -e "\e[94m4) Set Console/ttyd (root) password\e[0m" # Light Blue
    echo -e "\e[91m5) Uninstall Simple Admin\e[0m" # Light Red	
    echo -e "\e[95m6) Simple Firewall Management\e[0m" # Light Purple
    echo -e "\e[94m7) Tailscale Management\e[0m" # Light Blue
    echo -e "\e[92m8) Install/Change or remove Daily Reboot Timer\e[0m" # Light Green
    echo -e "\e[96m9) Install/Uninstall CFUN 0 Fix\e[0m" # Cyan (repeated color for additional options)
    echo -e "\e[91m10) Uninstall Entware/OPKG\e[0m" # Light Red
    echo -e "\e[92m11) Install Speedtest.net CLI app (speedtest command)\e[0m" # Light Green
    echo -e "\e[92m12) Install Fast.com CLI app (fast command)(tops out at 40Mbps)\e[0m" # Light Green
    echo -e "\e[92m13) Install OpenSSH Server\e[0m" # Light Green
    echo -e "\e[93m14) Exit\e[0m" # Yellow (repeated color for exit option)
    read -p "Enter your choice: " choice

    case $choice in
        1)
            send_at_commands
            ;;
        2)
            install_simple_admin
            ;;
		3)	set_simpleadmin_passwd
			;;
		4)
			set_root_passwd
			;;
		5)
			uninstall_simpleadmin_components
			;;
		6)
			configure_simple_firewall
            ;;
        
        7)  
			tailscale_menu
	        ;;
		8)
			manage_reboot_timer
            ;;
		9)
			manage_cfun_fix
            ;;	    
		10)
			echo -e "\033[31mAre you sure you want to uninstall entware?\033[0m"
			echo -e "\033[31m1) Yes\033[0m"
			echo -e "\033[31m2) No\033[0m"
			read -p "Select an option (1 or 2): " user_choice

			case $user_choice in
				1)
					# If yes, uninstall existing entware
					echo -e "\033[31mUninstalling existing entware...\033[0m"
					uninstall_entware  # Assuming uninstall_entware is a defined function or command
					echo -e "\033[31mEntware has been uninstalled.\033[0m"
					;;
				2)
					# If no, exit the script
					echo -e "\033[31mUninstallation cancelled.\033[0m"
					exit  # Use 'exit' to terminate the script outside a loop
					;;
				*)
					# Handle invalid input
					echo -e "\033[31mInvalid option. Please select 1 or 2.\033[0m"
					;;
			esac
			;;

		11) 
			ensure_entware_installed
			echo -e "\e[1;32mInstalling Speedtest.net CLI (speedtest command)\e[0m"
     	    remount_rw
			mkdir /usrdata/root
     	    mkdir /usrdata/root/bin
			cd /usrdata/root/bin
     	    wget https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-armhf.tgz
			tar -xzf ookla-speedtest-1.2.0-linux-armhf.tgz
     	    rm ookla-speedtest-1.2.0-linux-armhf.tgz
			rm speedtest.md
     	    cd /
			ln -sf /usrdata/root/bin/speedtest /bin
     	    remount_ro
			echo -e "\e[1;32mSpeedtest CLI (speedtest command) installed!!\e[0m"
     	    echo -e "\e[1;32mTry running the command 'speedtest'\e[0m"
			echo -e "\e[1;32mNote that it will not work unless you login to the root account first\e[0m"
			echo -e "\e[1;32mNormaly only an issue in adb, ttyd and ssh you are forced to login\e[0m"
			echo -e "\e[1;32mIf in adb just type login and then try to run the speedtest command\e[0m"
            ;;
		12) 
			echo -e "\e[1;32mInstalling fast.com CLI (fast command)\e[0m"
     	    remount_rw
			mkdir /usrdata/root
     	    mkdir /usrdata/root/bin
			cd /usrdata/root/bin
     	    wget -O fast https://github.com/ddo/fast/releases/download/v0.0.4/fast_linux_arm && chmod +x fast
     	    cd /
			ln -sf /usrdata/root/bin/fast /bin
     	    remount_ro
			echo -e "\e[1;32mFast.com CLI (speedtest command) installed!!\e[0m"
     	    echo -e "\e[1;32mTry running the command 'fast'\e[0m"
			echo -e "\e[1;32mThe fast.com test tops out at 40Mbps on the modem\e[0m"
            ;;
		13) 
			install_sshd
			;;
		14) 
			echo -e "\e[1;32mGoodbye!\e[0m"
     	    break
            ;;    
    *)
			echo -e "\e[1;31mInvalid option\e[0m"
            ;;
    esac
done
