#!/bin/bash

# Define constants
# Define GitHub repo info
GITUSER="iamromulan"
REPONAME="quectel-rgmii-toolkit"
GITTREE="SDXLEMUR"
GITMAINTREE="SDXLEMUR"
GITDEVTREE="development-SDXLEMUR"
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"
GITROOTMAIN="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITMAINTREE"
GITROOTDEV="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITDEVTREE"

# Define filesystem path
DIR_NAME="simplefirewall"
SERVICE_FILE="/lib/systemd/system/install_simplefirewall.service"
SERVICE_NAME="install_simplefirewall"
TMP_SCRIPT="/tmp/install_simple_firewall.sh"
LOG_FILE="/tmp/install_simplefirewall.log"

# Tmp Script dependent constants 
SIMPLE_FIREWALL_DIR="/usrdata/simplefirewall"
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
remount_rw
# Create the systemd service file
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Update $DIR_NAME temporary service

[Service]
Type=oneshot
ExecStart=/bin/bash $TMP_SCRIPT > $LOG_FILE 2>&1

[Install]
WantedBy=multi-user.target
EOF

# Create and populate the temporary shell script for installation
cat <<EOF > "$TMP_SCRIPT"
#!/bin/bash

# Define GitHub repo info
GITUSER="iamromulan"
REPONAME="quectel-rgmii-toolkit"
GITTREE="SDXLEMUR"
GITMAINTREE="SDXLEMUR"
GITDEVTREE="development-SDXLEMUR"
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"
GITROOTMAIN="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITMAINTREE"
GITROOTDEV="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITDEVTREE"

# Define filesystem path
SIMPLE_FIREWALL_DIR="/usrdata/simplefirewall"
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
remount_rw
# Function to remove Simple Firewall
uninstall_simple_firewall() {
	echo "Uninstalling Simplefirewall..."
    systemctl stop simplefirewall
    systemctl stop ttl-override
    rm -f /lib/systemd/system/simplefirewall.service
    rm -f /lib/systemd/system/ttl-override.service
    systemctl daemon-reload
    rm -rf "$SIMPLE_FIREWALL_DIR"
    echo "Simplefirewall uninstalled."
}
# Function to install Simple Firewall
install_simple_firewall() {
    systemctl stop simplefirewall
    systemctl stop ttl-override
    echo -e "\033[0;32mInstalling/Updating Simple Firewall...\033[0m"
    mount -o remount,rw /
    mkdir -p "$SIMPLE_FIREWALL_DIR"
    mkdir -p "$SIMPLE_FIREWALL_SYSTEMD_DIR"
    wget -O "$SIMPLE_FIREWALL_DIR/simplefirewall.sh" $GITROOT/simplefirewall/simplefirewall.sh
    wget -O "$SIMPLE_FIREWALL_DIR/ttl-override" $GITROOT/simplefirewall/ttl-override
    wget -O "$SIMPLE_FIREWALL_DIR/ttlvalue" $GITROOT/simplefirewall/ttlvalue
	chmod 666 $SIMPLE_FIREWALL_DIR/ttlvalue
    chmod +x "$SIMPLE_FIREWALL_DIR/simplefirewall.sh"
    chmod +x "$SIMPLE_FIREWALL_DIR/ttl-override"	
    wget -O "$SIMPLE_FIREWALL_SYSTEMD_DIR/simplefirewall.service" $GITROOT/simplefirewall/systemd/simplefirewall.service
    wget -O "$SIMPLE_FIREWALL_SYSTEMD_DIR/ttl-override.service" $GITROOT/simplefirewall/systemd/ttl-override.service
    cp -rf $SIMPLE_FIREWALL_SYSTEMD_DIR/* /lib/systemd/system
    ln -sf "/lib/systemd/system/simplefirewall.service" "/lib/systemd/system/multi-user.target.wants/"
    ln -sf "/lib/systemd/system/ttl-override.service" "/lib/systemd/system/multi-user.target.wants/"
    systemctl daemon-reload
    systemctl start simplefirewall
    systemctl start ttl-override
    echo -e "\033[0;32mSimple Firewall installation/update complete.\033[0m"
	}
uninstall_simple_firewall
install_simple_firewall
remount_ro
exit 0
EOF

# Make the temporary script executable
chmod +x "$TMP_SCRIPT"

# Reload systemd to recognize the new service and start the update
systemctl daemon-reload
systemctl start $SERVICE_NAME
