#!/bin/sh

# Define paths
USRDATA_DIR="/usrdata"
MICROPYTHON_DIR="/usrdata/micropython"
AT_TELNET_DIR="/usrdata/at-telnet"
SIMPLE_ADMIN_DIR="/usrdata/simpleadmin"
TMP_DIR="/tmp"
GITHUB_URL="https://github.com/iamromulan/quectel-rgmii-simpleadmin-at-telnet-daemon/archive/refs/heads/main.zip"


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
    cp -Rf quectel-rgmii-simpleadmin-at-telnet-daemon-main/attelnetdaemon/at-telnet $USRDATA_DIR
	cp -Rf quectel-rgmii-simpleadmin-at-telnet-daemon-main/attelnetdaemon/micropython $USRDATA_DIR

    # Set execute permissions
    chmod +x $MICROPYTHON_DIR/micropython
    chmod +x $AT_TELNET_DIR/modem-multiclient.py
    chmod +x $AT_TELNET_DIR/socat-armel-static
    chmod +x $AT_TELNET_DIR/picocom

    # Copy systemd unit files & reload
    cp -f $AT_TELNET_DIR/systemd_units/*.service /lib/systemd/system
    systemctl daemon-reload

    # Link systemd files
    ln -sf /lib/systemd/system/at-telnet-daemon.service /lib/systemd/system/multi-user.target.wants/
    ln -sf /lib/systemd/system/socat-smd11.service /lib/systemd/system/multi-user.target.wants/
    ln -sf /lib/systemd/system/socat-smd11-to-ttyIN.service /lib/systemd/system/multi-user.target.wants/
    ln -sf /lib/systemd/system/socat-smd11-from-ttyIN.service /lib/systemd/system/multi-user.target.wants/
    # Start Services
    systemctl start socat-smd11
    sleep 2s
    systemctl start socat-smd11-to-ttyIN
    systemctl start socat-smd11-from-ttyIN
    systemctl start at-telnet-daemon

    remount_ro
}

# Function to remove AT Telnet Daemon
remove_at_telnet() {
    remount_rw
    systemctl stop at-telnet-daemon
    systemctl disable at-telnet-daemon
    rm -rf $MICROPYTHON_DIR
	rm -rf $AT_TELNET_DIR
    rm /lib/systemd/system/at-telnet-daemon.service
    rm /lib/systemd/system/socat-smd11.service
    rm /lib/systemd/system/socat-smd11-to-ttyIN.service
    rm /lib/systemd/system/socat-smd11-from-ttyIN.service
    systemctl daemon-reload
    remount_ro
}

# Function to install/update Simple Admin
install_update_simple_admin() {
    remount_rw
    cd $TMP_DIR
    wget $GITHUB_URL -O main.zip
    unzip -o main.zip
    cp -Rf quectel-rgmii-simpleadmin-at-telnet-daemon-main/simpleadmin/ $USRDATA_DIR

    # Set execute permissions
    chmod +x $SIMPLE_ADMIN_DIR/scripts/*
    chmod +x $SIMPLE_ADMIN_DIR/www/cgi-bin/*
    chmod +x $SIMPLE_ADMIN_DIR/ttl/ttl-override

    # Copy systemd unit files & reload
    cp -f $SIMPLE_ADMIN_DIR/systemd/* /lib/systemd/system
    systemctl daemon-reload

    # Link systemd files
    ln -sf /lib/systemd/system/simpleadmin_httpd.service /lib/systemd/system/multi-user.target.wants/
    ln -sf /lib/systemd/system/simpleadmin_generate_status.service /lib/systemd/system/multi-user.target.wants/
    ln -sf /lib/systemd/system/ttl-override.service /lib/systemd/system/multi-user.target.wants/
    # Start Services
    systemctl start simpleadmin_generate_status
    systemctl start simpleadmin_httpd
    systemctl start ttl-override

    remount_ro
}

# Function to remove Simple Admin
remove_simple_admin() {
    remount_rw
    systemctl stop simpleadmin_httpd
    systemctl disable simpleadmin_httpd
    rm -rf $SIMPLE_ADMIN_DIR
    rm /lib/systemd/system/simpleadmin_httpd.service
    rm /lib/systemd/system/simpleadmin_generate_status.service
    rm /lib/systemd/system/ttl-override.service
    systemctl daemon-reload
    remount_ro
}

# Main menu
while true; do
    echo "Select an application to manage:"
    echo "1) AT Telnet Daemon"
    echo "2) Simple Admin"
    echo "3) Exit"
    read -p "Enter your choice: " choice

    case $choice in
         1)
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
        2)
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
        3) break;;
        *) echo "Invalid option";;
    esac
done

echo "Exiting script."
