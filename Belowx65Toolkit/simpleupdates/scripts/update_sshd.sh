#!/bin/bash

# Define constants
GITUSER="iamromulan"
GITTREE="development"
DIR_NAME="simpleupdates"
SERVICE_FILE="/lib/systemd/system/install_sshd.service"
SERVICE_NAME="install_sshd"
TMP_SCRIPT="/tmp/install_sshd.sh"
LOG_FILE="/tmp/install_sshd.log"

# Tmp Script dependent constants 


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

GITUSER="iamromulan"
GITTREE="development"

install_sshd() {
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
install_sshd
exit 0
EOF

# Make the temporary script executable
chmod +x "$TMP_SCRIPT"

# Reload systemd to recognize the new service and start the update
systemctl daemon-reload
systemctl start $SERVICE_NAME
