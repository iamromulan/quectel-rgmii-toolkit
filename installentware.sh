#!/bin/sh

# Entware installation script modified to use /usrdata/opt with a systemd mount unit

ARCH=armv7sf-k3.2
TYPE='alternative'

echo 'Info: Checking for prerequisites and creating folders...'
if grep -qs '/opt ' /proc/mounts; then
    echo 'Info: /opt is already mounted.'
else
    if [ ! -d /usrdata/opt ]; then
        mkdir -p /usrdata/opt
    fi
    # Create systemd mount unit to bind /usrdata/opt to /opt
    echo "Info: Creating systemd mount unit for /opt..."
    cat <<EOF > /etc/systemd/system/opt.mount
[Unit]
Description=Bind /usrdata/opt to /opt

[Mount]
What=/usrdata/opt
Where=/opt
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable opt.mount
    systemctl start opt.mount
fi

echo 'Info: Opkg package manager deployment...'
URL=http://bin.entware.net/${ARCH}/installer
wget $URL/opkg -O /opt/bin/opkg
chmod 755 /opt/bin/opkg
wget $URL/opkg.conf -O /opt/etc/opkg.conf

echo 'Info: Basic packages installation...'
/opt/bin/opkg update
if [ "$TYPE" = 'alternative' ]; then
  /opt/bin/opkg install busybox
fi
/opt/bin/opkg install entware-opt

# Fix for multiuser environment
chmod 777 /opt/tmp

# Create the rc.unslung start systemd service
echo "Info: Creating systemd service for Entware initialization..."
cat <<EOF > /etc/systemd/system/rc.unslung.service
[Unit]
Description=Start Entware services

[Service]
Type=oneshot
ExecStart=/opt/etc/init.d/rc.unslung start
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rc.unslung.service

echo 'Info: Congratulations!'
echo 'Info: If there are no errors above then Entware was successfully initialized.'
echo 'Info: Remember to add /opt/bin & /opt/sbin to your PATH variable.'
echo 'Info: Entware services will start automatically on boot.'
if [ "$TYPE" = 'alternative' ]; then
  echo 'Info: Use ssh server from Entware for better compatibility.'
fi
echo 'Info: Found a Bug? Please report at https://github.com/Entware/Entware/issues'
