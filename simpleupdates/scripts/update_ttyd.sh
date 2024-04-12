#!/bin/bash

# Define constants
GITUSER="iamromulan"
GITTREE="development"
SERVICE_FILE="/lib/systemd/system/install_ttyd.service"
TMP_SCRIPT="/tmp/install_ttyd.sh"

# Create the systemd service file
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Update ttyd service

[Service]
Type=oneshot
ExecStart=/bin/bash $TMP_SCRIPT

[Install]
WantedBy=multi-user.target
EOF

# Create and populate the temporary shell script for installation
cat <<EOF > "$TMP_SCRIPT"
#!/bin/bash
mount -o remount,rw /
echo -e "\e[1;34mUpdating ttyd...\e[0m"
systemctl stop ttyd
wget -O /usrdata/ttyd/ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.armhf && chmod +x /usrdata/ttyd/ttyd
wget -O /usrdata/ttyd/scripts/ttyd.bash "https://raw.githubusercontent.com/$GITUSER/$GITTREE/ttyd/scripts/ttyd.bash" && chmod +x /usrdata/ttyd/scripts/ttyd.bash
wget -O /usrdata/ttyd/systemd/ttyd.service "https://raw.githubusercontent.com/$GITUSER/$GITTREE/ttyd/systemd/ttyd.service"
cp -f /usrdata/ttyd/systemd/ttyd.service /lib/systemd/system/
systemctl daemon-reload
systemctl start ttyd
echo -e "\e[1;32mttyd has been updated.\e[0m"
EOF

# Make the temporary script executable
chmod +x "$TMP_SCRIPT"

# Reload systemd to recognize the new service and start the update
systemctl daemon-reload
systemctl start install_ttyd.service
