#!/bin/sh
# Modified by iamromulan to set up a proper entware environment for Quectel RM5xx series m.2 modems
TYPE='generic'
#|---------|-----------------|
#| TARGET  | Quectel Modem   |
#| ARCH    | armv7sf-k3.2    | 
#| LOADER  | ld-linux.so.3   | 
#| GLIBC   | 2.27            | 
#|---------|-----------------|
unset LD_LIBRARY_PATH
unset LD_PRELOAD
ARCH=armv7sf-k3.2
LOADER=ld-linux.so.3
GLIBC=2.27
PRE_OPKG_PATH=$(which opkg)

# Remount filesystem as read-write
mount -o remount,rw /

create_opt_mount() {
    # Bind /usrdata/opt to /opt
    echo -e '\033[32mInfo: Setting up /opt mount to /usrdata/opt...\033[0m'
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
    systemctl start opt.mount
    
    # Additional systemd service to ensure opt.mount starts at boot
    echo -e '\033[32mInfo: Creating service to start opt.mount at boot...\033[0m'
    cat <<EOF > /lib/systemd/system/start-opt-mount.service
[Unit]
Description=Ensure opt.mount is started at boot
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/systemctl start opt.mount

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    ln -s /lib/systemd/system/start-opt-mount.service /lib/systemd/system/multi-user.target.wants/start-opt-mount.service
}

if [ -n "$PRE_OPKG_PATH" ]; then
    # Automatically rename the existing opkg binary
    mv "$PRE_OPKG_PATH" "${PRE_OPKG_PATH}_old"
    echo -e "\033[32mFactory/Already existing opkg has been renamed to opkg_old.\033[0m"
else
    echo "Info: no existing opkg binary detected, proceeding with installation"
fi

echo -e '\033[32mInfo: Creating /opt mount pointed to /usrdata/opt ...\033[0m'
create_opt_mount
echo -e '\033[32mInfo: Proceeding with main installation ...\033[0m'
# no need to create many folders. entware-opt package creates most
for folder in bin etc lib/opkg tmp var/lock
do
  if [ -d "/opt/$folder" ]; then
    echo -e '\033[31mWarning: Folder /opt/$folder exists!\033[0m'
    echo -e '\033[31mWarning: If something goes wrong please clean /opt folder and try again.\033[0m'
  else
    mkdir -p /opt/$folder
  fi
done

echo -e '\033[32mInfo: Opkg package manager deployment...\033[0m'
URL=http://bin.entware.net/${ARCH}/installer
wget $URL/opkg -O /opt/bin/opkg
chmod 755 /opt/bin/opkg
wget $URL/opkg.conf -O /opt/etc/opkg.conf

echo -e '\033[32mInfo: Basic packages installation...\033[0m'
/opt/bin/opkg update
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

# Create and enable rc.unslung service
echo -e '\033[32mInfo: Creating rc.unslung (Entware init.d service)...\033[0m'
cat <<EOF > /lib/systemd/system/rc.unslung.service
[Unit]
Description=Start Entware services

[Service]
Type=oneshot
# Add a delay to give /opt time to mount
ExecStartPre=/bin/sleep 5
ExecStart=/opt/etc/init.d/rc.unslung start
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
ln -s /lib/systemd/system/rc.unslung.service /lib/systemd/system/multi-user.target.wants/rc.unslung.service
systemctl start rc.unslung.service
echo -e '\033[32mInfo: Congratulations!\033[0m'
echo -e '\033[32mInfo: If there are no errors above then Entware was successfully initialized.\033[0m'
echo -e '\033[32mInfo: Add /opt/bin & /opt/sbin to $PATH variable\033[0m'
ln -sf /opt/bin/opkg /bin
echo -e '\033[32mInfo: Patching Quectel Login Binary\033[0m'
opkg update && opkg install shadow-login shadow-passwd shadow-useradd
    if [ "$?" -ne 0 ]; then
        echo -e "\e[1;31mPackage installation failed. Please check your internet connection and try again.\e[0m"
        exit 1
    fi

    # Replace the login and passwd binaries and set home for root to a writable directory
    rm /opt/etc/shadow
    rm /opt/etc/passwd
    cp /etc/shadow /opt/etc/
    cp /etc/passwd /opt/etc
    mkdir /usrdata/root
    mkdir /usrdata/root/bin
    touch /usrdata/root/.profile
    echo "# Set PATH for all shells" > /usrdata/root/.profile
    echo "export PATH=/bin:/usr/sbin:/usr/bin:/sbin:/opt/sbin:/opt/bin:/usrdata/root/bin" >> /usrdata/root/.profile
    chmod +x /usrdata/root/.profile
    sed -i '1s|/home/root:/bin/sh|/usrdata/root:/bin/bash|' /opt/etc/passwd
    rm /bin/login /usr/bin/passwd
    ln -sf /opt/bin/login /bin
    ln -sf /opt/bin/passwd /usr/bin/
	ln -sf /opt/bin/useradd /usr/bin/
    echo -e "\e[1;31mPlease set the root password.\e[0m"
    /usr/bin/passwd

    # Install basic and useful utilites
    opkg install mc htop dfc lsof
    ln -sf /opt/bin/mc /bin
    ln -sf /opt/bin/htop /bin
    ln -sf /opt/bin/dfc /bin
    ln -sf /opt/bin/lsof /bin
# Remount filesystem as read-only
mount -o remount,ro /
