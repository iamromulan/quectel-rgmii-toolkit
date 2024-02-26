#!/bin/sh

TYPE='generic'
#|---------|-----------------|
#| ARCH    | armv7sf-k3.2    | 
#| LOADER  | ld-linux.so.3   | 
#| GLIBC   | 2.27            | 
#|---------|-----------------|
unset LD_LIBRARY_PATH
unset LD_PRELOAD
ARCH=armv7sf-k3.2
LOADER=ld-linux.so.3
GLIBC=2.27

# Remount filesystem as read-write
mount -o remount,rw /

# Check if /opt exists
if [ -d /opt ]; then
    echo -e "\033[32mDo you want to uninstall Entware/OPKG first? It is already installed.\033[0m"
    echo -e "\033[32m1) Yes\033[0m"
    echo -e "\033[32m2) No\033[0m"
    echo -e "\033[32m3) Cancel\033[0m"
    read -p "Select an option: " choice

    case $choice in
        1)
            # Call the uninstall function
            uninstall_entware
            exit 0
            ;;
        2)
            # Continue with the script
            echo "Continuing with the script..."
            ;;
        3)
            echo "Canceling. Exiting script."
            exit 0
            ;;            
        *)
            echo "Invalid option. Exiting."
            exit 1
            ;;
    esac
fi

uninstall_entware() {
    echo -e '\033[31mInfo: Starting Entware/OPKG uninstallation...\033[0m'

    # Stop services
    systemctl stop rc.unslung.service
    rm /lib/systemd/system/multi-user.target.wants/rc.unslung.service
    rm /lib/systemd/system/rc.unslung.service
    
    systemctl stop opt.mount
    rm /lib/systemd/system/multi-user.target.wants/start-opt-mount.service
    rm /lib/systemd/system/opt.mount
    rm /lib/systemd/system/start-opt-mount.service

    # Unmount /opt if mounted
    mountpoint -q /opt && umount /opt

    # Remove Entware installation directory
    rm -rf /usrdata/opt
    rm -rf /opt

    # Reload systemctl daemon
    systemctl daemon-reload

    # Optionally, clean up any modifications to /etc/profile or other system files
    # This step depends on the specific changes made by the user or the installation script

    echo -e '\033[32mInfo: Entware/OPKG has been uninstalled successfully.\033[0m'
}

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

echo -e '\033[32mInfo: Checking for /opt...\033[0m'
if [ -d /opt ]; then
    echo -e '\033[31mWarning: /opt exists!\033[0m'
else
    create_opt_mount
fi
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
echo -e '\033[32mInfo: Run export PATH=/opt/bin:/opt/sbin:$PATH to do it for this session only\033[0m'
echo -e '\033[32mInfo: opkg at /opt/bin will be linked to /bin but any package you install with opkg will not be automatically.\033[0m'
ln -sf /opt/bin/opkg /bin
opkg update
# Remount filesystem as read-only
mount -o remount,ro /
