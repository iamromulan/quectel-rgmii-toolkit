#!/bin/bash

#
# Removes SimpleAdmin
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
