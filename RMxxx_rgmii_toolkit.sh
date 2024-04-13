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
LIGHTTPD_DIR="/usrdata/lighttpd"
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
            /usr/bin/passwd

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

# Check if Simple Admin is installed
is_simple_admin_installed() {
    [ -d "$SIMPLE_ADMIN_DIR" ] && return 0 || return 1
}

# Function to install/update AT Socat Bridge
install_update_at_socat() {
    remount_rw
    
	# Stop and disable existing services/files before installing new ones
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
	
	# Install service units
	echo -e "\033[0;32mInstalling AT Socat Bridge services...\033[0m"
	mkdir $SOCAT_AT_DIR
    cd $SOCAT_AT_DIR
    mkdir $SOCAT_AT_SYSD_DIR
    wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/socat-armel-static
    wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/killsmd7bridge
    wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/atcmd
    cd $SOCAT_AT_SYSD_DIR
    wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/systemd_units/socat-smd11.service
    wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/systemd_units/socat-smd11-from-ttyIN.service
    wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/systemd_units/socat-smd11-to-ttyIN.service
    wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/systemd_units/socat-killsmd7bridge.service	
    wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/systemd_units/socat-smd7-from-ttyIN2.service
    wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/systemd_units/socat-smd7-to-ttyIN2.service
    wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/socat-at-bridge/systemd_units/socat-smd7.service

    # Set execute permissions
    cd $SOCAT_AT_DIR
    chmod +x socat-armel-static
    chmod +x killsmd7bridge
    chmod +x atcmd
	
    # Link new command for AT Commands from the shell
    ln -sf $SOCAT_AT_DIR/atcmd /bin
	
    # Install service units
    echo -e "\033[0;32mAdding AT Socat Bridge systemd service units...\033[0m"
    cp -rf $SOCAT_AT_SYSD_DIR/*.service /lib/systemd/system
    ln -sf /lib/systemd/system/socat-killsmd7bridge.service /lib/systemd/system/multi-user.target.wants/
    ln -sf /lib/systemd/system/socat-smd11.service /lib/systemd/system/multi-user.target.wants/
    ln -sf /lib/systemd/system/socat-smd11-to-ttyIN.service /lib/systemd/system/multi-user.target.wants/
    ln -sf /lib/systemd/system/socat-smd11-from-ttyIN.service /lib/systemd/system/multi-user.target.wants/
    ln -sf /lib/systemd/system/socat-smd7.service /lib/systemd/system/multi-user.target.wants/
    ln -sf /lib/systemd/system/socat-smd7-to-ttyIN2.service /lib/systemd/system/multi-user.target.wants/
    ln -sf /lib/systemd/system/socat-smd7-from-ttyIN2.service /lib/systemd/system/multi-user.target.wants/
    systemctl daemon-reload
    systemctl start socat-smd11
    sleep 2s
    systemctl start socat-smd11-to-ttyIN
    systemctl start socat-smd11-from-ttyIN
    echo -e "\033[0;32mAT Socat Bridge service online: smd11 to ttyOUT\033[0m"
    systemctl start socat-killsmd7bridge
    sleep 1s
    systemctl start socat-smd7
    sleep 2s
    systemctl start socat-smd7-to-ttyIN2
    systemctl start socat-smd7-from-ttyIN2
    echo -e "\033[0;32mAT Socat Bridge service online: smd7 to ttyOUT2\033[0m"
    remount_ro
    cd /
    echo -e "\033[0;32mAT Socat Bridge services Installed!\033[0m"
}

# Function to install Simple Firewall
install_simple_firewall() {
	remount_rw
    systemctl stop simplefirewall
    systemctl stop ttl-override
    echo -e "\033[0;32mInstalling/Updating Simple Firewall...\033[0m"
    mount -o remount,rw /
    mkdir -p "$SIMPLE_FIREWALL_DIR"
    mkdir -p "$SIMPLE_FIREWALL_SYSTEMD_DIR"
    wget -O "$SIMPLE_FIREWALL_DIR/simplefirewall.sh" https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simplefirewall/simplefirewall.sh
    wget -O "$SIMPLE_FIREWALL_DIR/ttl-override" https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simplefirewall/ttl-override
    wget -O "$SIMPLE_FIREWALL_DIR/ttlvalue" https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simplefirewall/ttlvalue
    chmod +x "$SIMPLE_FIREWALL_DIR/simplefirewall.sh"
    chmod +x "$SIMPLE_FIREWALL_DIR/ttl-override"	
    wget -O "$SIMPLE_FIREWALL_SYSTEMD_DIR/simplefirewall.service" https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simplefirewall/systemd/simplefirewall.service
    wget -O "$SIMPLE_FIREWALL_SYSTEMD_DIR/ttl-override.service" https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simplefirewall/systemd/ttl-override.service
    cp -rf $SIMPLE_FIREWALL_SYSTEMD_DIR/* /lib/systemd/system
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

# Function to install Lighttpd
install_lighttpd() {
    ensure_entware_installed
	remount_rw
	# Check for simpleadmin_httpd service and remove if exists
    if [ -f "/lib/systemd/system/simpleadmin_httpd.service" ]; then
        systemctl stop simpleadmin_httpd
        rm /lib/systemd/system/simpleadmin_httpd.service
        rm /lib/systemd/system/multi-user.target.wants/simpleadmin_httpd.service
    fi

    /opt/bin/opkg install lighttpd lighttpd-mod-auth lighttpd-mod-authn_file lighttpd-mod-cgi lighttpd-mod-openssl lighttpd-mod-proxy
    # Ensure rc.unslung doesn't try to start it
    # Dynamically find and remove any Lighttpd-related init script
    for script in /opt/etc/init.d/*lighttpd*; do
        if [ -f "$script" ]; then
            echo "Removing existing Lighttpd init script: $script"
            rm "$script" # Remove the script if it contains 'lighttpd' in its name
        fi
    done
    systemctl stop lighttpd
    echo -e "\033[0;32mInstalling/Updating Lighttpd...\033[0m"
    mkdir -p "$SIMPLE_ADMIN_DIR"
    wget -O "$SIMPLE_ADMIN_DIR/lighttpd.conf" https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/lighttpd.conf
    wget -O "/lib/systemd/system/lighttpd.service" https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/lighttpd.service
    ln -sf "/lib/systemd/system/lighttpd.service" "/lib/systemd/system/multi-user.target.wants/"

    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=MI/L=Romulus/O=RMIITools/CN=localhost" \
        -keyout $SIMPLE_ADMIN_DIR/server.key -out $SIMPLE_ADMIN_DIR/server.crt
    systemctl daemon-reload
    systemctl start lighttpd
    
    echo -e "\033[0;32mLighttpd installation/update complete.\033[0m"

    while true; do
        echo -e "\e[1;31mPlease set your simpleadmin (User: admin) web login password.\e[0m"
        read -s password
        if [ -z "$password" ]; then
            echo -e "\e[1;32mNo password provided.\e[0m"
        else
            echo -n "admin:" > $SIMPLE_ADMIN_DIR/.htpasswd
            openssl passwd -crypt "$password" >> $SIMPLE_ADMIN_DIR/.htpasswd
            echo -e "\e[1;32mPassword set.\e[0m"
            break
        fi
    done
}

# Function to install or update ttyd
install_ttyd() {
    echo -e "\e[1;34mStarting ttyd installation process...\e[0m"

    ensure_entware_installed

    mount -o remount,rw /

    if [ ! -d "/usrdata/lighttpd" ]; then
        install_lighttpd
    fi

    if [ -d "/usrdata/ttyd" ]; then
        echo -e "\e[1;34mttyd is already installed. Choose an option:\e[0m"
        echo -e "\e[1;34m1.) Update to ttyd 1.7.7 (If you are using ttyd you will temporarly loose connection, update will continue ...)\e[0m"
        echo -e "\e[1;31m2.) Skip Update (Chose this if you already updated)\e[0m"
        read -p "Enter your choice (1/2): " choice
        case $choice in
            1)
                echo -e "\e[1;34mUpdating ttyd...\e[0m"
		echo -e "\e[1;34mIf you are using ttyd you will temporarly loose connection ...\e[0m"
  		mkdir /usrdata/simpleupdates
		mkdir /usrdata/simpleupdates/scripts
		wget -O /usrdata/simpleupdates/scripts/update_ttyd.sh https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleupdates/scripts/update_ttyd.sh && chmod +x /usrdata/simpleupdates/scripts/update_ttyd.sh
		/usrdata/simpleupdates/scripts/update_ttyd.sh
                echo -e "\e[1;32mttyd has been updated.\e[0m"
                ;;
            2)
                echo -e "\e[1;34mSkiping ttyd update...\e[0m"
                ;;
            *)
                echo -e "\e[1;31mInvalid option. Exiting.\e[0m"
                exit 1
                ;;
        esac
        return
    fi

    # Continue with installation if ttyd is not already installed.
    # Check for /usrdata/socat-at-bridge/atcmd, install if not installed
    if [ ! -f "/usrdata/socat-at-bridge/atcmd" ]; then
        echo -e "\e[1;34mDependency: atcmd command does not exist. Installing socat-at-bridge...\e[0m"
        install_update_at_socat
        if [ "$?" -ne 0 ]; then
            echo -e "\e[1;31mFailed to install/update atcmd. Please check the process.\e[0m"
            exit 1
        fi
    fi
    mkdir -p /usrdata/ttyd/scripts /usrdata/ttyd/systemd
    cd /usrdata/ttyd/
    wget -O ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.armhf && chmod +x ttyd
    wget -O scripts/ttyd.bash "https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/ttyd/scripts/ttyd.bash" && chmod +x scripts/ttyd.bash
    wget -O systemd/ttyd.service "https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/ttyd/systemd/ttyd.service"
    cp systemd/ttyd.service /lib/systemd/system/
    ln -sf /usrdata/ttyd/ttyd /bin
    
    # Enabling and starting ttyd service
    systemctl daemon-reload
    ln -sf /lib/systemd/system/ttyd.service /lib/systemd/system/multi-user.target.wants/
    systemctl start ttyd
    if [ "$?" -ne 0 ]; then
        echo -e "\e[1;31mFailed to start ttyd service. Please check the systemd service file and ttyd binary.\e[0m"
        exit 1
    fi

    echo -e "\e[1;32mInstallation Complete! ttyd server is up on port 443. Note: No TLS/SSL enabled yet.\e[0m"
}

# Function to handle ttyd upgrade
check_and_install_ttyd() {
	remount_rw
    local service_file="/lib/systemd/system/ttyd.service"
    local exec_start_expected1="/usrdata/ttyd/ttyd -p 443 -t 'theme={\"foreground\":\"white\",\"background\":\"black\"}' -t fontSize=25 --writable /usrdata/ttyd/scripts/ttyd.bash"
    local exec_start_expected2="/usrdata/ttyd/ttyd -i 127.0.0.1 -p 8080 -t 'theme={\"foreground\":\"white\",\"background\":\"black\"}' -t fontSize=25 --writable /usrdata/ttyd/scripts/ttyd.bash"

    if [ -f "$service_file" ]; then
        # Extract ExecStart line from ttyd.service
        local exec_start=$(grep ExecStart $service_file)

        if [ "$exec_start" == "ExecStart=$exec_start_expected1" ]; then
            install_ttyd
        elif [ "$exec_start" == "ExecStart=$exec_start_expected2" ]; then
            # Continue without action
            echo "No action required, ttyd service is configured as expected."
        else
            install_ttyd
        fi
    else
        install_ttyd
    fi
}

# Function to install/update Simple Admin
install_simple_admin() {
    while true; do
	echo -e "\e[1;32mWhat version of Simple Admin do you want to install? This will start a webserver on port 8080 (80/443 on test build)\e[0m"
    echo -e "\e[1;32m1) Stable current version, (Main Branch)\e[0m"
	echo -e "\e[1;31m2) Install Test Build (Development Branch)\e[0m"
	echo -e "\e[0;33m3) Return to Main Menu\e[0m"
 	echo -e "\e[1;32mSelect your choice: \e[0m"
        read choice

        case $choice in
        1)
			echo -e "\e[1;32mInstalling simpleadmin from the main stable branch\e[0m"
			install_update_at_socat
			sleep 1
			install_simple_firewall
			sleep 1
            remount_rw
			sleep 1
			mkdir $SIMPLE_ADMIN_DIR
			mkdir $SIMPLE_ADMIN_DIR/systemd
    		mkdir $SIMPLE_ADMIN_DIR/scripts
      		mkdir $SIMPLE_ADMIN_DIR/www
			mkdir $SIMPLE_ADMIN_DIR/www/cgi-bin
			mkdir $SIMPLE_ADMIN_DIR/www/css
    		mkdir $SIMPLE_ADMIN_DIR/www/js
            cd $SIMPLE_ADMIN_DIR/systemd
            wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/systemd/simpleadmin_generate_status.service
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/main/simpleadmin/systemd/simpleadmin_httpd.service
			sleep 1
			cd $SIMPLE_ADMIN_DIR/scripts
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/scripts/build_modem_status
    		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/scripts/modemstatus_parse.sh
      		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/scripts/tojson.sh
			sleep 1
			cd $SIMPLE_ADMIN_DIR/www
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/atcommander.html
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/index.html
    		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/speedtest.html
      		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/styles.css
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/ttl.html
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/bandlock.html
			sleep 1
			cd $SIMPLE_ADMIN_DIR/www/js
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/js/alpinejs.min.js
    		sleep 1
    		cd $SIMPLE_ADMIN_DIR/www/css
    		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/css/admin.css
      		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/css/bulma.css
			sleep 1
			cd $SIMPLE_ADMIN_DIR/www/cgi-bin
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/cgi-bin/get_atcommand
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/cgi-bin/get_csq
    		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/cgi-bin/get_ttl_status
      		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITMAINTREE/simpleadmin/www/cgi-bin/set_ttl
			sleep 1
			cd /
            chmod +x $SIMPLE_ADMIN_DIR/scripts/*
            chmod +x $SIMPLE_ADMIN_DIR/www/cgi-bin/*
            cp -rf $SIMPLE_ADMIN_DIR/systemd/* /lib/systemd/system
            systemctl daemon-reload
			sleep 1
			ln -sf /lib/systemd/system/simpleadmin_httpd.service /lib/systemd/system/multi-user.target.wants/
            ln -sf /lib/systemd/system/simpleadmin_generate_status.service /lib/systemd/system/multi-user.target.wants/
            systemctl start simpleadmin_generate_status
			sleep 1
            remount_ro
            echo -e "\e[1;32msimpleadmin has been installed and is now ready for use!\e[0m"
            break
			;;
        2)
			echo -e "\e[1;31m2) Installing simpleadmin from the development test branch\e[0m"
			install_update_at_socat
			sleep 1
			install_simple_firewall
			sleep 1
			install_lighttpd
			sleep 1
            remount_rw
			sleep 1
			mkdir $SIMPLE_ADMIN_DIR
			mkdir $SIMPLE_ADMIN_DIR/systemd
    		mkdir $SIMPLE_ADMIN_DIR/scripts
      		mkdir $SIMPLE_ADMIN_DIR/www
			mkdir $SIMPLE_ADMIN_DIR/www/cgi-bin
			mkdir $SIMPLE_ADMIN_DIR/www/css
    		mkdir $SIMPLE_ADMIN_DIR/www/js
            cd $SIMPLE_ADMIN_DIR/systemd
            wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/systemd/simpleadmin_generate_status.service
			sleep 1
			cd $SIMPLE_ADMIN_DIR/scripts
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/scripts/build_modem_status
    		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/scripts/modemstatus_parse.sh
      		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/scripts/tojson.sh
			sleep 1
			cd $SIMPLE_ADMIN_DIR/www
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/atcommander.html
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/index.html
    		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/speedtest.html
      		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/styles.css
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/ttl.html
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/sms.html
    		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/bandlock.html
			sleep 1
			cd $SIMPLE_ADMIN_DIR/www/js
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/js/alpinejs.min.js
    		sleep 1
    		cd $SIMPLE_ADMIN_DIR/www/css
    		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/css/admin.css
      		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/css/bulma.css
			sleep 1
			cd $SIMPLE_ADMIN_DIR/www/cgi-bin
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/cgi-bin/get_atcommand
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/cgi-bin/get_csq
    		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/cgi-bin/get_ttl_status
      		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITDEVTREE/simpleadmin/www/cgi-bin/set_ttl
			sleep 1
			cd /
            chmod +x $SIMPLE_ADMIN_DIR/scripts/*
            chmod +x $SIMPLE_ADMIN_DIR/www/cgi-bin/*
            cp -rf $SIMPLE_ADMIN_DIR/systemd/* /lib/systemd/system
			sleep 1
            systemctl daemon-reload
			sleep 1
            ln -sf /lib/systemd/system/simpleadmin_generate_status.service /lib/systemd/system/multi-user.target.wants/
            systemctl start simpleadmin_generate_status
			sleep 1
			check_and_install_ttyd
			sleep 1
            remount_ro
            echo -e "\e[1;32msimpleadmin has been installed and is now ready for use!\e[0m"
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
    echo -e "\e[1;36mIf you are upgrading from an older version of the toolkit uninstall/say yes to all everything except ttyd.\e[0m"
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
    echo -e "\e[1;32mDo you want to uninstall ttyd?\e[0m"
	echo -e "\e[1;31mWarning: Do not uninstall if you are currently using ttyd to do this!!!\e[0m"
	echo -e "\e[1;31mInstalling the test build will prompt ttyd to be updated if it needs it anyways\e[0m"
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
		opkg --force-remove remove lighttpd-mod-auth lighttpd-mod-authn_file lighttpd-mod-cgi lighttpd-mod-openssl lighttpd-mod-proxy lighttpd
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
	echo -e "\e[1;32m1) Install/Update/Remove Tailscale\e[0m"
	echo -e "\e[1;36m2) Configure Tailscale\e[0m"
	echo -e "\e[1;31m3) Return to Main Menu\e[0m"
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
 	echo "Downloading binary files..."
 	cd /usrdata
  	wget https://pkgs.tailscale.com/stable/tailscale_1.62.1_arm.tgz
   	tar -xzf tailscale_1.62.1_arm.tgz
    	cd /usrdata/tailscale_1.62.1_arm
     	mv tailscale $TAILSCALE_DIR/tailscale
	mv tailscaled $TAILSCALE_DIR/tailscaled
        cd $TAILSCALE_DIR
	rm -rf /usrdata/tailscale_1.62.1_arm
    	echo "Downloading systemd files..."
     	cd $TAILSCALE_SYSD_DIR
      	wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/main/tailscale/systemd/tailscaled.service
       	wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/main/tailscale/systemd/tailscaled.defaults
	sleep 2s
	echo "Setting Permissions..."
        chmod +x /usrdata/tailscale/tailscaled
        chmod +x /usrdata/tailscale/tailscale
	echo "Copy systemd units..."
        cp -rf /usrdata/tailscale/systemd/* /lib/systemd/system
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
	    echo -e "\e[1;32mOpenSSH Server\e[0m"
        remount_rw

	    mkdir /usrdata/sshd
        wget -O /lib/systemd/system/sshd.service "https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/sshd/sshd.service"
    	ln -sf "/lib/systemd/system/sshd.service" "/lib/systemd/system/multi-user.target.wants/"
        
        opkg install openssh-server-pam
        for script in /opt/etc/init.d/*sshd*; do
        if [ -f "$script" ]; then
            echo "Removing existing sshd init script: $script"
            rm "$script" # Remove the script if it contains 'sshd' in its name
        fi
		done
        /opt/bin/ssh-keygen -A
        systemctl daemon-reload
        systemctl enable sshd

        # Enable PAM and PermitRootLogin
        sed -i "s/^.*UsePAM .*/UsePAM yes/" "/opt/etc/ssh/sshd_config"
        sed -i "s/^.*PermitRootLogin .*/PermitRootLogin yes/" "/opt/etc/ssh/sshd_config"

        # Ensure the sshd user exists in the /opt/etc/passwd file
        grep "sshd:x:106" /opt/etc/passwd || echo "sshd:x:106:65534:Linux User,,,:/opt/run/sshd:/bin/nologin" >> /opt/etc/passwd
        systemctl start sshd

	    echo -e "\e[1;32mOpenSSH installed!!\e[0m"
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
    echo -e "\e[93m2) Install/Update/Uninstall Simple Admin\e[0m" # Yellow
    echo -e "\e[95m3) Simple Firewall Management\e[0m" # Light Purple
    echo -e "\e[94m4) Tailscale Management\e[0m" # Light Blue
    echo -e "\e[92m5) Install/Change or remove Daily Reboot Timer\e[0m" # Light Green
    echo -e "\e[91m6) Install/Uninstall CFUN 0 Fix\e[0m" # Light Red
    echo -e "\e[96m7) Install/Uninstall Entware/OPKG\e[0m" # Cyan (repeated color for additional options)
    echo -e "\e[92m8) Install Speedtest.net CLI app (speedtest command)\e[0m" # Light Green
    echo -e "\e[92m9) Install Fast.com CLI app (fast command)(tops out at 40Mbps)\e[0m" # Light Green
    echo -e "\e[92m10) Install OpenSSH Server\e[0m" # Light Green
    echo -e "\e[93m11) Exit\e[0m" # Yellow (repeated color for exit option)
    read -p "Enter your choice: " choice

    case $choice in
        1)
            send_at_commands
            ;;
        2)
            if is_simple_admin_installed; then
                echo -e "\e[1;31mSimple Admin is already installed. It must be removed first\e[0m"
                echo -e "\e[1;32m1) Remove\e[0m"  # Green
		echo -e "\e[0;33m2) Return to main menu\e[0m"
                read -p "Enter your choice: " simple_admin_choice
                case $simple_admin_choice in
                    1) uninstall_simpleadmin_components;;
                    2) break;;
                    *) echo -e "\e[1;31mInvalid option\e[0m";;
                esac
            else
                echo -e "\e[1;32mInstalling Simple Admin...\e[0m"
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
	    ensure_entware_installed
            ;;
	8) 
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
	9) 
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
	10) 
		install_sshd
        ;;
	11) 
	    echo -e "\e[1;32mGoodbye!\e[0m"
     	    break
            ;;    
    *)
        echo -e "\e[1;31mInvalid option\e[0m"
            ;;
    esac
done
