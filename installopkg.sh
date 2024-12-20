#!/bin/sh

#|---------|-------------------------|
#| TARGET  | SDXLEMUR                |
#| ARCH    | arm_cortex-a7_neon-vfpv4|
#|---------|-------------------------|

# Based on entware, heavily modified by iamromulan
# This script sets up a custom opkg installation system for the SDXLEMUR platform
# The primary feed for this will be my feed and will be a combo of modified IPK files from multiple sources
# opkg is from entware and expects /opt to exist
# /opt will be setup as an overlay of lower / and upper /usrdata/rootfs-upper
# Most likely several mount binds will be setup at / to point back to /opt the overlay
# The real /lib/systemd will need to be able to be written to so we may bind that within /opt
# In active development; will decide if the entware feed gets re added later


ARCH=arm_cortex-a7_neon-vfpv4
#ARCH=armv7sf-k3.2
PRE_OPKG_PATH=$(which opkg)
URL=https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/development-SDXLEMUR/opkg-feed/installer

# Remount filesystem as read-write
mount -o remount,rw /

# Will need to edit this. Will be an overlay instead of bind mount
# The package sdxlemur-mount-fix will make this run at boot
create_opt_overlay() {

[ ! -d "/opt" ] && mkdir /opt
[ ! -d "/usrdata/rootfs-upper" ] && mkdir /usrdata/rootfs-upper
[ ! -d "/usrdata/rootfs-work" ] && mkdir /usrdata/rootfs-work

mount -t overlay overlay_root -o lowerdir=/,upperdir=/usrdata/rootfs-upper,workdir=/usrdata/rootfs-work /opt

# add additional mount binds and dir

}

# Account for existing opkg binary on the RM502Q-AE
if [ -n "$PRE_OPKG_PATH" ]; then
    # Automatically rename the existing opkg binary
    mv "$PRE_OPKG_PATH" "${PRE_OPKG_PATH}_old"
    echo -e "\033[32mFactory/Already existing opkg has been renamed to opkg_old.\033[0m"
else
    echo "Info: no existing opkg binary detected, proceeding with installation"
fi

echo -e '\033[32mInfo: Creating /opt overlayfs with lower / and upper /usrdata/rootfs-upper \033[0m'
create_opt_overlay

echo -e '\033[32mInfo: Proceeding with main installation ...\033[0m'
echo -e '\033[32mInfo: Opkg package manager deployment...\033[0m'

wget $URL/opkg -O /opt/bin/opkg
chmod 755 /opt/bin/opkg
wget $URL/opkg.conf -O /opt/etc/opkg.conf

echo -e '\033[32mInfo: Basic packages installation...\033[0m'
/opt/bin/opkg update
#/opt/bin/opkg install entware-opt #Will revist this and its need
/opt/bin/opkg install sdxlemur-factory-packages

# Fix for multiuser environment
chmod 777 /opt/tmp


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
echo -e '\033[32mInfo: Congratulations!\033[0m'
echo -e '\033[32mInfo: If there are no errors above then Entware was successfully initialized.\033[0m'
