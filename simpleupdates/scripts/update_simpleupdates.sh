#!/bin/bash

# WORK IN PROGRESS

# Define constants
GITUSER="iamromulan"
GITTREE="development"
DIR_NAME="simpleupdates"
SERVICE_FILE="/lib/systemd/system/install_simpleupdates.service"
SERVICE_NAME="install_simpleupdates"
TMP_SCRIPT="/tmp/install_simpleupdates.sh"
LOG_FILE="/tmp/install_simpleupdates.log"

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

install_simpleupdates() {
# CONTENT
}
install_simpleupdates
exit 0
EOF

# Make the temporary script executable
chmod +x "$TMP_SCRIPT"

# Reload systemd to recognize the new service and start the update
systemctl daemon-reload
systemctl start $SERVICE_NAME
