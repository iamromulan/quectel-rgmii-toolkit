#!/bin/sh

# Define paths
USRDATA_DIR="/usrdata"
MICROPYTHON_DIR="/usrdata/micropython"
AT_TELNET_DIR="/usrdata/at-telnet"
AT_TELNET_SYSD_DIR="/usrdata/at-telnet/systemd_units"
AT_TELNET_SMD7_SYSD_DIR="/usrdata/at-telnet/smd7_systemd_units"
SIMPLE_ADMIN_DIR="/usrdata/simpleadmin"
TMP_DIR="/tmp"
GITHUB_URL="https://github.com/iamromulan/quectel-rgmii-toolkit/archive/refs/heads/main.zip"
GITHUB_SIMPADMIN_FULL_URL="https://github.com/iamromulan/quectel-rgmii-toolkit/archive/refs/heads/simpleadminfull.zip"
GITHUB_SIMPADMIN_NOCMD_URL="https://github.com/iamromulan/quectel-rgmii-toolkit/archive/refs/heads/simpleadminnoatcmds.zip"
GITHUB_SIMPADMIN_TTL_URL="https://github.com/iamromulan/quectel-rgmii-toolkit/archive/refs/heads/simpleadminttlonly.zip"
TAILSCALE_DIR="/usrdata/tailscale/"
TAILSCALE_SYSD_DIR="/usrdata/tailscale/systemd"
SIMPLE_FIREWALL_DIR="/usrdata/simplefirewall"
SIMPLE_FIREWALL_SCRIPT="$SIMPLE_FIREWALL_DIR/simplefirewall.sh"
SIMPLE_FIREWALL_SYSTEMD_DIR="$SIMPLE_FIREWALL_DIR/systemd"
SIMPLE_FIREWALL_SERVICE="/lib/systemd/system/simplefirewall.service"

# AT Command Script Variables and Functions
DEVICE_FILE="/dev/smd7"
TIMEOUT=4  # Set a timeout for the response

start_listening() {
    cat "$DEVICE_FILE" > /tmp/device_readout &
    CAT_PID=$!
}

send_at_command() {
    echo "Enter AT command (or type 'exit' to quit): "
    read at_command
    if [ "$at_command" = "exit" ]; then
        return 1
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

# Function to remount file system as read-write
remount_rw() {
    mount -o remount,rw /
}

# Function to remount file system as read-only
remount_ro() {
    mount -o remount,ro /
}

# Check if AT Telnet Daemon is installed
is_at_telnet_installed() {
    [ -d "$MICROPYTHON_DIR" ] && return 0 || return 1
	[ -d "$AT_TELNET_DIR" ] && return 0 || return 1
}

# Function to check if Simple Firewall is installed
is_simple_firewall_installed() {
    if [ -d "$SIMPLE_FIREWALL_DIR" ]; then
        return 0
    else
        return 1
    fi
}

# Check if Simple Admin is installed
is_simple_admin_installed() {
    [ -d "$SIMPLE_ADMIN_DIR" ] && return 0 || return 1

# Function to install/update Simple Firewall
install_update_simple_firewall() {
    echo "Installing/Updating Simple Firewall..."
    mount -o remount,rw /
    mkdir -p "$SIMPLE_FIREWALL_DIR"
    mkdir -p "$SIMPLE_FIREWALL_SYSTEMD_DIR"
    wget -O "$SIMPLE_FIREWALL_SCRIPT" https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/simplefirewall/simplefirewall.sh
    chmod +x "$SIMPLE_FIREWALL_SCRIPT"
    wget -O "$SIMPLE_FIREWALL_SYSTEMD_DIR/simplefirewall.service" https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/simplefirewall/systemd/simplefirewall.service
    cp -f "$SIMPLE_FIREWALL_SYSTEMD_DIR/simplefirewall.service" "$SIMPLE_FIREWALL_SERVICE"
    ln -sf "$SIMPLE_FIREWALL_SERVICE" "/lib/systemd/system/multi-user.target.wants/"
    systemctl daemon-reload
    systemctl restart simplefirewall
    mount -o remount,ro /
    echo "Simple Firewall installation/update complete."
}

# Function to uninstall Simple Firewall
uninstall_simple_firewall() {
    echo "Uninstalling Simple Firewall..."
    mount -o remount,rw /
    systemctl stop simplefirewall
    rm -f "/lib/systemd/system/multi-user.target.wants/simplefirewall.service"
    rm -f "$SIMPLE_FIREWALL_SERVICE"
    rm -rf "$SIMPLE_FIREWALL_DIR"
    systemctl daemon-reload
    mount -o remount,ro /
    echo "Simple Firewall uninstalled."
}

# Function to configure Simple Firewall
configure_simple_firewall() {
    if [ ! -f "$SIMPLE_FIREWALL_SCRIPT" ]; then
        echo "Simple Firewall script not found."
        return
    fi

    # Extract current ports configuration
    current_ports_line=$(grep '^PORTS=' "$SIMPLE_FIREWALL_SCRIPT")
    ports=$(echo "$current_ports_line" | cut -d'=' -f2 | tr -d '()' | tr ' ' '\n' | grep -o '[0-9]\+')
    echo "$ports" | awk '{print NR") "$0}'

    while true; do
        echo "Enter a port number to add/remove, or type 'done' to finish:"
        read port
        if [ "$port" = "done" ]; then
            break
        elif ! echo "$port" | grep -qE '^[0-9]+$'; then
            echo "Invalid input: Please enter a numeric value."
        elif echo "$ports" | grep -q "^$port\$"; then
            # Remove port
            ports=$(echo "$ports" | grep -v "^$port\$")
            echo "Port $port removed."
        else
            # Add port
            ports=$(echo "$ports"; echo "$port" | grep -o '[0-9]\+')
            echo "Port $port added."
        fi
    done

    # Prepare updated ports line
    new_ports_line="PORTS=($(echo "$ports" | tr '\n' ' '))"
    
    # Update the script with new ports
    sed -i "s/$current_ports_line/$new_ports_line/" "$SIMPLE_FIREWALL_SCRIPT"
    systemctl restart simplefirewall
    echo "Firewall configuration updated."
}




# Function for Simplefirewall Submenu
simplefirewall_menu() {
while true; do
    echo "Simple Firewall Management"
    echo "1) Install/Update/Uninstall Simple Firewall"
    echo "2) Configure Simple Firewall"
    echo "3) Exit"
    read -p "Enter your choice: " choice

    case $choice in
        1)
            if is_simple_firewall_installed; then
                echo "Simple Firewall is already installed."
                echo "1) Update Simple Firewall"
                echo "2) Uninstall Simple Firewall"
                read -p "Enter your choice: " update_uninstall_choice
                case $update_uninstall_choice in
                    1) install_update_simple_firewall;;
                    2) uninstall_simple_firewall;;
                    *) echo "Invalid option";;
                esac
            else
                install_update_simple_firewall
            fi
            ;;
        2)
            configure_simple_firewall
            ;;
        3)
            echo "Exiting..."
            break
            ;;
        *)
            echo "Invalid option"
            ;;
    esac
done
}


# Function to install/update AT Telnet Daemon
install_update_at_telnet() {
    remount_rw
    mkdir $MICROPYTHON_DIR
    mkdir $AT_TELNET_DIR
    cd $MICROPYTHON_DIR
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/micropython/errno.py
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/micropython/fcntl.py
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/micropython/ffilib.py
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/micropython/logging.py
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/micropython/micropython
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/micropython/os_compat.py
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/micropython/serial.py
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/micropython/stat.py
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/micropython/time.py
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/micropython/traceback.mpy
    cd $AT_TELNET_DIR
    mkdir $AT_TELNET_SYSD_DIR
    mkdir $AT_TELNET_SMD7_SYSD_DIR
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/at-telnet/modem-multiclient.py
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/at-telnet/picocom
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/at-telnet/socat-armel-static
    cd $AT_TELNET_SYSD_DIR
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/at-telnet/systemd_units/socat-smd11.service
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/at-telnet/systemd_units/at-telnet-daemon.service
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/at-telnet/systemd_units/socat-smd11-from-ttyIN.service
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/at-telnet/systemd_units/socat-smd11-to-ttyIN.service
    cd $AT_TELNET_SMD7_SYSD_DIR
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/at-telnet/smd7_systemd_units/at-telnet-daemon.service
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/at-telnet/smd7_systemd_units/socat-smd7-from-ttyIN.service
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/at-telnet/smd7_systemd_units/socat-smd7-to-ttyIN.service
    wget https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/attelnetdaemon/at-telnet/smd7_systemd_units/socat-smd7.service

    # Set execute permissions
    chmod +x $MICROPYTHON_DIR/micropython
    chmod +x $AT_TELNET_DIR/modem-multiclient.py
    chmod +x $AT_TELNET_DIR/socat-armel-static
    chmod +x $AT_TELNET_DIR/picocom

    # User prompt for selecting device
    echo "Which device should AT over Telnet use?"
    echo "This will create virtual tty ports (serial ports) that will use either smd11 or smd7"
    echo "1) Use smd11 (default)"
    echo "2) Use smd7 (use this if another application is using smd11)"
    read -p "Enter your choice (1 or 2): " device_choice

    # Stop and disable existing services before installing new ones
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

    # Depending on the choice, copy the respective systemd unit files
    case $device_choice in
        2)
            cp -f $AT_TELNET_SMD7_SYSD_DIR/*.service /lib/systemd/system
			ln -sf /lib/systemd/system/socat-smd7.service /lib/systemd/system/multi-user.target.wants/
			ln -sf /lib/systemd/system/socat-smd7-to-ttyIN.service /lib/systemd/system/multi-user.target.wants/
			ln -sf /lib/systemd/system/socat-smd7-from-ttyIN.service /lib/systemd/system/multi-user.target.wants/
			systemctl daemon-reload
			systemctl start socat-smd7
			sleep 2s
			systemctl start socat-smd7-to-ttyIN
			systemctl start socat-smd7-from-ttyIN
            ;;
        1)
            cp -f $AT_TELNET_SYSD_DIR/*.service /lib/systemd/system
			ln -sf /lib/systemd/system/socat-smd11.service /lib/systemd/system/multi-user.target.wants/
			ln -sf /lib/systemd/system/socat-smd11-to-ttyIN.service /lib/systemd/system/multi-user.target.wants/
			ln -sf /lib/systemd/system/socat-smd11-from-ttyIN.service /lib/systemd/system/multi-user.target.wants/
			systemctl daemon-reload
			systemctl start socat-smd11
			sleep 2s
			systemctl start socat-smd11-to-ttyIN
			systemctl start socat-smd11-from-ttyIN
            ;;
    esac

    

    # User prompt for enabling Telnet server
    echo "-Telnet server is not required for simpleadmin"
    echo "-Simpleadmin uses the tty port created in the previous step"
    echo "-If enabled a telnet server will listen on the gateway address on port 5000"
    echo "-It isn't password protceted though so it is recommended to only enable if you need it" 
    echo "Enable Telnet server?"
    echo "1) Yes"
    echo "2) No"
    read -p "Enter your choice (1 or 2): " telnet_choice

    # Link or remove systemd files based on user choice
    if [ "$telnet_choice" = "1" ]; then
        ln -sf /lib/systemd/system/at-telnet-daemon.service /lib/systemd/system/multi-user.target.wants/
		
        # Start Services
        systemctl start at-telnet-daemon
	remount_ro
    else
        remount_ro
    fi
    
}

# Function to remove AT Telnet Daemon
remove_at_telnet() {
    remount_rw
    # Stop and disable all possible services related to AT Telnet Daemon
    systemctl stop at-telnet-daemon
    systemctl disable at-telnet-daemon
    systemctl stop socat-smd11
    systemctl stop socat-smd11-to-ttyIN
    systemctl stop socat-smd11-from-ttyIN
    systemctl stop socat-smd7
    systemctl stop socat-smd7-to-ttyIN
    systemctl stop socat-smd7-from-ttyIN

    # Remove all systemd service files for both smd11 and smd7 configurations
    rm /lib/systemd/system/at-telnet-daemon.service
    rm /lib/systemd/system/socat-smd11.service
    rm /lib/systemd/system/socat-smd11-to-ttyIN.service
    rm /lib/systemd/system/socat-smd11-from-ttyIN.service
    rm /lib/systemd/system/socat-smd7.service
    rm /lib/systemd/system/socat-smd7-to-ttyIN.service
    rm /lib/systemd/system/socat-smd7-from-ttyIN.service

    # Reload systemd to apply changes
    systemctl daemon-reload

    # Prompt user before removing micropython
    echo "Do you want to remove MicroPython?"
    echo "1) Yes"
    echo "2) No"
    read -p "Enter your choice: " choice

    case $choice in
        1 )
            rm -rf $MICROPYTHON_DIR
            echo "MicroPython directory removed."
            ;;
        2 )
            echo "MicroPython directory not removed."
            ;;
        * )
            echo "Invalid choice. MicroPython directory not removed."
            ;;
    esac

    # Remove the AT Telnet Daemon directory
    rm -rf $AT_TELNET_DIR
    remount_ro
    echo "AT Telnet Daemon removed successfully."
}


# Function to install/update Simple Admin
install_update_simple_admin() {
    while true; do
        echo "Make sure to Install AT Telnet Daemon first. You don't need to Enable the Telnet Server if you don't need it"
	echo "What version of Simple Admin do you want to install? This will start a webserver on port 8080"
        echo "1) Full Install"
        echo "2) No AT Commands, List only (for use with firmware that already has a web UI)"
        echo "3) TTL Only"
        echo "4) Return to Main Menu"
        echo "Select your choice: "
        read choice

        case $choice in
            1)
                remount_rw
                cd $TMP_DIR
                wget $GITHUB_SIMPADMIN_FULL_URL -O simpleadminfull.zip
                unzip -o simpleadminfull.zip
                cp -Rf quectel-rgmii-toolkit-simpleadminfull/simpleadmin/ $USRDATA_DIR

                chmod +x $SIMPLE_ADMIN_DIR/scripts/*
                chmod +x $SIMPLE_ADMIN_DIR/www/cgi-bin/*
                chmod +x $SIMPLE_ADMIN_DIR/ttl/ttl-override

                cp -f $SIMPLE_ADMIN_DIR/systemd/* /lib/systemd/system
                systemctl daemon-reload

                ln -sf /lib/systemd/system/simpleadmin_httpd.service /lib/systemd/system/multi-user.target.wants/
                ln -sf /lib/systemd/system/simpleadmin_generate_status.service /lib/systemd/system/multi-user.target.wants/
                ln -sf /lib/systemd/system/ttl-override.service /lib/systemd/system/multi-user.target.wants/

                systemctl start simpleadmin_generate_status
                systemctl start simpleadmin_httpd
                systemctl start ttl-override
                remount_ro
                break
                ;;
            2)
                remount_rw
                cd $TMP_DIR
                wget $GITHUB_SIMPADMIN_NOCMD_URL -O simpleadminnoatcmds.zip
                unzip -o simpleadminnoatcmds.zip
                cp -Rf quectel-rgmii-toolkit-simpleadminnoatcmds/simpleadmin/ $USRDATA_DIR

                chmod +x $SIMPLE_ADMIN_DIR/scripts/*
                chmod +x $SIMPLE_ADMIN_DIR/www/cgi-bin/*
                chmod +x $SIMPLE_ADMIN_DIR/ttl/ttl-override

                cp -f $SIMPLE_ADMIN_DIR/systemd/* /lib/systemd/system
                systemctl daemon-reload

                ln -sf /lib/systemd/system/simpleadmin_httpd.service /lib/systemd/system/multi-user.target.wants/
                ln -sf /lib/systemd/system/simpleadmin_generate_status.service /lib/systemd/system/multi-user.target.wants/
                ln -sf /lib/systemd/system/ttl-override.service /lib/systemd/system/multi-user.target.wants/

                systemctl start simpleadmin_generate_status
                systemctl start simpleadmin_httpd
                systemctl start ttl-override
                remount_ro
		echo "Cleaning up..."
  		rm /tmp/simpleadminnoatcmds.zip
   		rm -rf /tmp/quectel-rgmii-toolkit-simpleadminnoatcmds/
                break
                ;;
            3)
                remount_rw
                cd $TMP_DIR
                wget $GITHUB_SIMPADMIN_TTL_URL -O simpleadminttlonly.zip
                unzip -o simpleadminttlonly.zip
                cp -Rf quectel-rgmii-toolkit-simpleadminttlonly/simpleadmin/ $USRDATA_DIR

                chmod +x $SIMPLE_ADMIN_DIR/www/cgi-bin/*
                chmod +x $SIMPLE_ADMIN_DIR/ttl/ttl-override

                cp -f $SIMPLE_ADMIN_DIR/systemd/* /lib/systemd/system
                systemctl daemon-reload

                ln -sf /lib/systemd/system/simpleadmin_httpd.service /lib/systemd/system/multi-user.target.wants/
                ln -sf /lib/systemd/system/ttl-override.service /lib/systemd/system/multi-user.target.wants/

                systemctl start simpleadmin_httpd
                systemctl start ttl-override
                remount_ro
		echo "Cleaning up..."
 	 	rm /tmp/simpleadminttlonly.zip
   		rm -rf /tmp/quectel-rgmii-toolkit-simpleadminttlonly/
                break
                ;;
            4)
                echo "Returning to main menu..."
                break
                ;;
            *)
                echo "Invalid choice. Please try again."
                ;;
        esac
    done
}



# Function to remove Simple Admin
remove_simple_admin() {
    remount_rw
    systemctl stop simpleadmin_generate_status
    systemctl stop ttl-override
    systemctl stop simpleadmin_httpd
    systemctl disable simpleadmin_httpd
    systemctl disable ttl-override
    systemctl disable simpleadmin_httpd
    rm -rf $SIMPLE_ADMIN_DIR
    rm /lib/systemd/system/simpleadmin_httpd.service
    rm /lib/systemd/system/simpleadmin_generate_status.service
    rm /lib/systemd/system/ttl-override.service
    systemctl daemon-reload
    remount_ro
}

# Function to create systemd service and timer files with the user-specified time
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
                remount_rw
		$TAILSCALE_DIR/tailscale down
                $TAILSCALE_DIR/tailscale logout
                systemctl stop tailscaled
                # Follow the installation steps with force overwrite
		echo "Downloading the latest Tailscale binaries..."
		wget -O $TAILSCALE_DIR/tailscaled https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/tailscale/tailscaled
		wget -O $TAILSCALE_DIR/tailscale https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/tailscale/tailscale

		echo "Setting permissions for the new binaries..."
		chmod +x $TAILSCALE_DIR/tailscaled
		chmod +x $TAILSCALE_DIR/tailscale

		echo "Downloading the latest systemd files..."
		wget -O $TAILSCALE_SYSD_DIR/tailscaled.service https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/tailscale/systemd/tailscaled.service
		wget -O $TAILSCALE_SYSD_DIR/tailscaled.defaults https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/tailscale/systemd/tailscaled.defaults

		echo "Copying the new systemd units..."
		cp -f $TAILSCALE_SYSD_DIR/* /lib/systemd/system
		systemctl daemon-reload

		echo "Restarting Tailscaled service..."
		systemctl restart tailscaled

		echo "Tailscale updated successfully."
               
                remount_ro
                echo "Tailscale updated successfully."
				echo "You will need to reconnect and Log back in"
				read -p "Press Enter to continue..."
                ;;
            2) 
                echo "Removing Tailscale..."
		remount_rw
                $TAILSCALE_DIR/tailscale down
                $TAILSCALE_DIR/tailscale logout
                systemctl stop tailscaled
                systemctl disable tailscaled
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
	echo "5) Connect to Tailnet with SSH OFF (reset flag)"
	echo "6) Disconnect from Tailnet (reconnects at reboot)"
        echo "7) Logout from tailscale account"
	echo "8) Return to Tailscale Menu"
        read -p "Enter your choice: " config_choice

        case $config_choice in
            1)
		remount_rw
		cd /lib/systemd/system/
		wget -O tailscale-webui.service https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/tailscale/systemd/tailscale-webui.service
     		ln -sf /lib/systemd/system/tailscale-webui.service /lib/systemd/system/multi-user.target.wants/
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
    		systemctl disable tailscale-webui
  		rm /lib/systemd/system/multi-user.target.wants/tailscale-webui.service
    		rm /lib/systemd/system/tailscale-webui.service
     		systemctl daemon-reload
       		echo "Tailscale Web UI Stopped and Disabled"
     	   	remount_ro
		;;
	    3) $TAILSCALE_DIR/tailscale up;;
            4) $TAILSCALE_DIR/tailscale up --ssh;;
	    5) $TAILSCALE_DIR/tailscale up --reset;;
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

# Main menu
while true; do
    echo "Welcome to iamromulan's RGMII Toolkit script for Quectel RMxxx Series modems!"
    echo "Select an option:"
    echo "1) Send AT Commands"
    echo "2) Install/Update/Uninstall or Configure Simple Firewall"
    echo "3) Install/Update or remove AT Telnet Daemon"
    echo "4) Install/Update or remove Simple Admin"
    echo "5) Tailscale Management"
    echo "6) Install/Change or remove Daily Reboot Timer"
    echo "7) Exit"
    read -p "Enter your choice: " choice

    case $choice in
        1)
            send_at_commands
            ;;
        2)
	    simplefirewall_menu
            ;;
	3)
            if is_at_telnet_installed; then
                echo "AT Telnet Daemon is already installed."
                echo "1) Update"
                echo "2) Remove"
                read -p "Enter your choice: " at_telnet_choice
                case $at_telnet_choice in
                    1) install_update_at_telnet;;
                    2) remove_at_telnet;;
                    *) echo "Invalid option";;
                esac
            else
                echo "Installing AT Telnet Daemon..."
                install_update_at_telnet
            fi
            ;;
        4)
            if is_simple_admin_installed; then
                echo "Simple Admin is already installed."
                echo "1) Update"
                echo "2) Remove"
                read -p "Enter your choice: " simple_admin_choice
                case $simple_admin_choice in
                    1) install_update_simple_admin;;
                    2) remove_simple_admin;;
                    *) echo "Invalid option";;
                esac
            else
                echo "Installing Simple Admin..."
                install_update_simple_admin
            fi
            ;;
        5)  
	    tailscale_menu
	    ;;
	6)
            manage_reboot_timer
            ;;
        7) 
	    echo "Goodbye!"
     	    break
            ;;
        *)
            echo "Invalid option"
            ;;
    esac
done

echo "Exiting script."
}
