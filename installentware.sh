#!/bin/sh

#TYPE='generic'
TYPE='alternative'

#|---------|-----------------------|---------------|---------------|---------------------|-------------------|-------------------|----------------------|-------------------|
#| ARCH    | aarch64-k3.10         | armv5sf-k3.2  | armv7sf-k2.6  | armv7sf-k3.2        | mipselsf-k3.4     | mipssf-k3.4       | x64-k3.2             | x86-k2.6          |
#| LOADER  | ld-linux-aarch64.so.1 | ld-linux.so.3 | ld-linux.so.3 | ld-linux.so.3       | ld.so.1           | ld.so.1           | ld-linux-x86-64.so.2 | ld-linux.so.2     |
#| GLIBC   | 2.27                  | 2.27          | 2.23          | 2.27                | 2.27              | 2.27              | 2.27                 | 2.23              |
#|---------|-----------------------|---------------|---------------|---------------------|-------------------|-------------------|----------------------|-------------------|

unset LD_LIBRARY_PATH
unset LD_PRELOAD

ARCH=armv7sf-k3.2
LOADER=ld-linux.so.3
GLIBC=2.27

# Remount filesystem as read-write
mount -o remount,rw /

echo 'Info: Checking for prerequisites and creating folders...'
if [ -d /opt ]; then
    echo 'Warning: Folder /opt exists!'
else
    mkdir /opt
fi
# no need to create many folders. entware-opt package creates most
for folder in bin etc lib/opkg tmp var/lock
do
  if [ -d "/opt/$folder" ]; then
    echo "Warning: Folder /opt/$folder exists!"
    echo 'Warning: If something goes wrong please clean /opt folder and try again.'
  else
    mkdir -p /opt/$folder
  fi
done

echo 'Info: Opkg package manager deployment...'
URL=http://bin.entware.net/${ARCH}/installer
wget $URL/opkg -O /opt/bin/opkg
chmod 755 /opt/bin/opkg
wget $URL/opkg.conf -O /opt/etc/opkg.conf

echo 'Info: Basic packages installation...'
/opt/bin/opkg update
if [ $TYPE = 'alternative' ]; then
  /opt/bin/opkg install busybox
fi
/opt/bin/opkg install entware-opt

# Fix for multiuser environment
chmod 777 /opt/tmp

for file in passwd group shells shadow gshadow; do
  if [ $TYPE = 'generic' ]; then
    if [ -f /etc/$file ]; then
      ln -sf /etc/$file /opt/etc/$file
    else
      [ -f /opt/etc/$file.1 ] && cp /opt/etc/$file.1 /opt/etc/$file
    fi
  else
    if [ -f /opt/etc/$file.1 ]; then
      cp /opt/etc/$file.1 /opt/etc/$file
    fi
  fi
done

[ -f /etc/localtime ] && ln -sf /etc/localtime /opt/etc/localtime

# Move /opt to /usrdata/opt after installation
echo 'Info: Moving Entware to /usrdata/opt...'
mkdir -p /usrdata/opt
mv /opt/* /usrdata/opt/

# Bind /usrdata/opt to /opt
echo 'Info: Setting up /opt mount to /usrdata/opt...'
cat <<EOF > /lib/systemd/system/opt.mount
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
ln -s /lib/systemd/system/opt.mount /lib/systemd/system/multi-user.target.wants/opt.mount
systemctl start opt.mount

# Update /etc/profile for PATH
echo 'Info: Updating /etc/profile for PATH...'
if ! grep -q 'PATH=.*opt/bin' /etc/profile; then
    sed -i 's|PATH="|PATH="/opt/bin:/opt/sbin:|' /etc/profile
fi

# Create and enable rc.unslung service
echo 'Info: Creating rc.unslung service...'
cat <<EOF > /lib/systemd/system/rc.unslung.service
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
ln -s /lib/systemd/system/rc.unslung.service /lib/systemd/system/multi-user.target.wants/rc.unslung.service
systemctl start rc.unslung.service

echo 'Info: Congratulations!'
echo 'Info: If there are no errors above then Entware was successfully initialized.'
echo 'Info: Add /opt/bin & /opt/sbin to $PATH variable'
if [ $TYPE = 'alternative' ]; then
  echo 'Info: Use ssh server from Entware for better compatibility.'
fi
echo 'Info: Found a Bug? Please report at https://github.com/Entware/Entware/issues'
# Remount filesystem as read-only
mount -o remount,ro /
