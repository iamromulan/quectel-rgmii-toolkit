#!/bin/sh

# Define paths
USRDATA_DIR="/usrdata"
MICROPYTHON_DIR="/usrdata/micropython"
AT_TELNET_DIR="/usrdata/at-telnet"
SIMPLE_ADMIN_DIR="/usrdata/simpleadmin"
TMP_DIR="/tmp"
GITHUB_URL="https://github.com/iamromulan/quectel-rgmii-toolkit/archive/refs/heads/main.zip"
GITHUB_SIMPADMIN_NOCMD_URL="https://github.com/iamromulan/quectel-rgmii-toolkit/archive/refs/heads/simpleadminnoatcmds.zip"
GITHUB_SIMPADMIN_TTL_URL="https://github.com/iamromulan/quectel-rgmii-toolkit/archive/refs/heads/simpleadminttlonly.zip"
TAILSCALE_DIR="/usrdata/tailscale/"

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

# Check if AT Telnet Daemon is installed
is_at_telnet_installed() {
    [ -d "$MICROPYTHON_DIR" ] && return 0 || return 1
	[ -d "$AT_TELNET_DIR" ] && return 0 || return 1
}

# Check if Simple Admin is installed
is_simple_admin_installed() {
    [ -d "$SIMPLE_ADMIN_DIR" ] && return 0 || return 1
}

# Function to remount file system as read-write
remount_rw() {
    mount -o remount,rw /
}

# Function to remount file system as read-only
remount_ro() {
    mount -o remount,ro /
}

# Function to install/update AT Telnet Daemon
install_update_at_telnet() {
    remount_rw
    cd $TMP_DIR
    wget $GITHUB_URL -O main.zip
    unzip -o main.zip
    cp -Rf quectel-rgmii-toolkit-main/attelnetdaemon/at-telnet $USRDATA_DIR
    cp -Rf quectel-rgmii-toolkit-main/attelnetdaemon/micropython $USRDATA_DIR

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
            cp -f $AT_TELNET_DIR/smd7_systemd_units/*.service /lib/systemd/system
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
            cp -f $AT_TELNET_DIR/systemd_units/*.service /lib/systemd/system
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
 	# Cleanup
  	echo "Cleaning up..."
  	rm /tmp/main.zip
   	rm -rf /tmp/quectel-rgmii-toolkit-main/
    else
        remount_ro
 	# Cleanup
  	echo "Cleaning up..."
  	rm /tmp/main.zip
   	rm -rf /tmp/quectel-rgmii-toolkit-main/
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

    # Additional cleanup if necessary
    # (Add any other file or directory removals here if needed)

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
                wget $GITHUB_URL -O main.zip
                unzip -o main.zip
                cp -Rf quectel-rgmii-toolkit-main/simpleadmin/ $USRDATA_DIR

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
  		rm /tmp/main.zip
   		rm -rf /tmp/quectel-rgmii-toolkit-main/
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
                $TAILSCALE_DIR/tailscale down
                $TAILSCALE_DIR/tailscale logout
                systemctl stop tailscaled
                # Follow the installation steps with force overwrite
                remount_rw
                cd $TMP_DIR
                wget $GITHUB_URL -O main.zip
                unzip -o main.zip
                cp -Rf quectel-rgmii-toolkit-main/tailscale/ $USRDATA_DIR
                chmod +x /usrdata/tailscale/tailscaled
                chmod +x /usrdata/tailscale/tailscale
                cp -f /usrdata/tailscale/systemd/* /lib/systemd/system
                systemctl daemon-reload
                ln -sf /lib/systemd/system/tailscaled.service /lib/systemd/system/multi-user.target.wants/
		echo "Starting Tailscaled..."
                systemctl start tailscaled
		echo "Cleaning up..."
  		rm /tmp/main.zip
   		rm -rf /tmp/quectel-rgmii-toolkit-main/
                remount_ro
                echo "Tailscale updated successfully."
				echo "You will need to reconnect and Log back in"
				read -p "Press Enter to continue..."
                ;;
            2) 
                echo "Removing Tailscale..."
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
        cd $TMP_DIR
        wget $GITHUB_URL -O main.zip
        unzip -o main.zip
        cp -Rf quectel-rgmii-toolkit-main/tailscale/ $USRDATA_DIR
        chmod +x /usrdata/tailscale/tailscaled
        chmod +x /usrdata/tailscale/tailscale
        cp -f /usrdata/tailscale/systemd/* /lib/systemd/system
        systemctl daemon-reload
        ln -sf /lib/systemd/system/tailscaled.service /lib/systemd/system/multi-user.target.wants/
	echo "Starting Tailscaled..."
        systemctl start tailscaled
        remount_ro
	echo "Cleaning up..."
  	rm /tmp/main.zip
   	rm -rf /tmp/quectel-rgmii-toolkit-main/
        echo "Tailscale installed successfully."
    fi
}


# Function to Configure Tailscale
configure_tailscale() {
    while true; do
        echo "Configure Tailscale"
        echo "1) Connect to Tailnet"
        echo "2) Connect to Tailnet with SSH ON"
		echo "3) Connect to Tailnet with SSH OFF (reset flag)"
		echo "4) Disconnect from Tailnet (reconnects at reboot)"
        echo "5) Logout from tailscale account"
		echo "6) Return to Tailscale Menu"
        read -p "Enter your choice: " config_choice

        case $config_choice in
            1) $TAILSCALE_DIR/tailscale up;;
            2) $TAILSCALE_DIR/tailscale up --ssh;;
			3) $TAILSCALE_DIR/tailscale up --reset;;
			4) $TAILSCALE_DIR/tailscale down;;
			5) $TAILSCALE_DIR/tailscale logout;;
            6) break;;
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
    echo "2) Install/Update or remove AT Telnet Daemon"
    echo "3) Install/Update or remove Simple Admin"
    echo "4) Tailscale Management"
	echo "5) Install/Change or remove Daily Reboot Timer"
    echo "6) Exit"
    read -p "Enter your choice: " choice

    case $choice in
        1)
            send_at_commands
            ;;
        2)
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
        3)
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
        4)  
			tailscale_menu
			;;
		5)
            manage_reboot_timer
            ;;
        6) 
        # Cleanup
  	    echo "Cleaning up..."
  	    rm /tmp/main.zip
            rm -rf /tmp/quectel-rgmii-toolkit-main/
	    echo "Goodbye!"
     	    break
            ;;
        *)
            echo "Invalid option"
            ;;
    esac
done

echo "Exiting script."
