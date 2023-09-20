#!/bin/bash

#
# Removes SimpleAdmin and AT Telnet Daemon
#

read -p "Do you want to uninstall SimpleAdmin (yes/no) " yn

case $yn in
	yes ) echo ok, we will proceed;;
	no ) echo exiting...;
		exit;;
	* ) echo invalid response;
		exit 1;;
esac

# ExecStop

systemctl stop simpleadmin_generate_status.timer
systemctl stop simpleadmin_generate_status
systemctl stop simpleadmin_httpd
systemctl stop ttl-override

#Remove from /usrdata

rm -rf /usrdata/simpleadmin

# Remount
mount -o remount,rw /

# Copy systemd init files & reload
#remove links
rm /lib/systemd/system/multi-user.target.wants/simpleadmin_httpd.service
rm /lib/systemd/system/multi-user.target.wants/simpleadmin_generate_status.service
rm /lib/systemd/system/timers.target.wants/simpleadmin_generate_status.timer
rm /lib/systemd/system/multi-user.target.wants/ttl-override.service

#remove files
rm /lib/systemd/system/simpleadmin_generate_status.timer
rm /lib/systemd/system/simpleadmin_httpd.service
rm /lib/systemd/system/simpleadmin_generate_status.service
rm /lib/systemd/system/ttl-override.service

systemctl daemon-reload

# Link systemd files

# Remount readonly
mount -o remount,ro /


read -p "Do you want to uninstall AT Telnet Daemon (yes/no) " yn

case $yn in
	yes ) echo ok, we will proceed;;
	no ) echo exiting...;
		exit;;
	* ) echo invalid response;
		exit 1;;
esac

# ExecStop

systemctl at-telnet-daemon socat-smd11 socat-smd11-to-ttyIN socat-smd11-from-ttyIN

#Remove from /usrdata

rm -rf /usrdata/at-telnet
rm -rf /usrdata/micropython

# Remount
mount -o remount,rw /

# Copy systemd init files & reload
#remove links
rm /lib/systemd/system/multi-user.target.wants/at-telnet-daemon.service
rm /lib/systemd/system/multi-user.target.wants/socat-smd11.service
rm /lib/systemd/system/timers.target.wants/socat-smd11-to-ttyIN.service
rm /lib/systemd/system/multi-user.target.wants/socat-smd11-from-ttyIN.service

#remove files
rm /lib/systemd/system/at-telnet-daemon.service
rm /lib/systemd/system/socat-smd11.service
rm /lib/systemd/system/socat-smd11-to-ttyIN.service
rm /lib/systemd/system/socat-smd11-from-ttyIN.service

systemctl daemon-reload

# Link systemd files

# Remount readonly
mount -o remount,ro /