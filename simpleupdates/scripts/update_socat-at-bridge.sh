#!/bin/bash

# Define constants
# Define GitHub repo info
GITUSER="iamromulan"
REPONAME="quectel-rgmii-toolkit"
GITTREE="development-SDXLEMUR"
GITMAINTREE="SDXLEMUR"
GITDEVTREE="development-SDXLEMUR"
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"
GITROOTMAIN="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITMAINTREE"
GITROOTDEV="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITDEVTREE"
# Define filesystem path
DIR_NAME="socat-at-bridge"
SERVICE_FILE="/lib/systemd/system/install_socat-at-bridge.service"
SERVICE_NAME="install_socat-at-bridge"
TMP_SCRIPT="/tmp/install_socat-at-bridge.sh"
LOG_FILE="/tmp/install_socat-at-bridge.log"

# Tmp Script dependent constants 
SOCAT_AT_DIR="/usrdata/socat-at-bridge"
SOCAT_AT_SYSD_DIR="/usrdata/socat-at-bridge/systemd_units"
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
SOCAT_AT_DIR="/usrdata/socat-at-bridge"
SOCAT_AT_SYSD_DIR="/usrdata/socat-at-bridge/systemd_units"

# Function to remount file system as read-write
remount_rw() {
    mount -o remount,rw /
}

# Function to remount file system as read-only
remount_ro() {
    mount -o remount,ro /
}
remount_rw
uninstall_at_socat() {
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
}

install_at_socat() {
	# Install service units
	echo -e "\033[0;32mInstalling AT Socat Bridge services...\033[0m"
	mkdir $SOCAT_AT_DIR
    cd $SOCAT_AT_DIR
    mkdir $SOCAT_AT_SYSD_DIR
    wget $GITROOT/socat-at-bridge/socat-armel-static
    wget $GITROOT/socat-at-bridge/killsmd7bridge
    wget $GITROOT/socat-at-bridge/atcmd
	wget $GITROOT/socat-at-bridge/atcmd11
    cd $SOCAT_AT_SYSD_DIR
    wget $GITROOT/socat-at-bridge/systemd_units/socat-smd11.service
    wget $GITROOT/socat-at-bridge/systemd_units/socat-smd11-from-ttyIN.service
    wget $GITROOT/socat-at-bridge/systemd_units/socat-smd11-to-ttyIN.service
    wget $GITROOT/socat-at-bridge/systemd_units/socat-killsmd7bridge.service	
    wget $GITROOT/socat-at-bridge/systemd_units/socat-smd7-from-ttyIN2.service
    wget $GITROOT/socat-at-bridge/systemd_units/socat-smd7-to-ttyIN2.service
    wget $GITROOT/socat-at-bridge/systemd_units/socat-smd7.service

    # Set execute permissions
    cd $SOCAT_AT_DIR
    chmod +x socat-armel-static
    chmod +x killsmd7bridge
    chmod +x atcmd
	chmod +x atcmd11
	
    # Link new command for AT Commands from the shell
    ln -sf $SOCAT_AT_DIR/atcmd /bin
	ln -sf $SOCAT_AT_DIR/atcmd11 /bin
	
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
uninstall_at_socat
install_at_socat
remount_ro
exit 0
EOF

# Make the temporary script executable
chmod +x "$TMP_SCRIPT"

# Reload systemd to recognize the new service and start the update
systemctl daemon-reload
systemctl start $SERVICE_NAME
