#!/bin/bash

#
# Installs SimpleAdmin
#

read -p "Do you want to install SimpleAdmin (yes/no) " yn

case $yn in
	yes ) echo ok, we will proceed;;
	no ) echo exiting...;
		exit;;
	* ) echo invalid response;
		exit 1;;
esac


# Download
cd /tmp
wget https://github.com/rbflurry/quectel-rgmii-simpleadmin/archive/refs/heads/main.zip

# Unzip
unzip main.zip
cp -R quectel-rgmii-simpleadmin-main* simpleadmin/

# Copy over to /usrdata
cp -R /tmp/simpleadmin /usrdata/

# Chmod execute on scripts and cgi-bin
chmod +x /usrdata/simpleadmin/scripts/* /usrdata/simpleadmin/www/cgi-bin/* /usrdata/simpleadmin/ttl/ttl-override

# Remount
mount -o remount,rw /

# Copy systemd init files & reload
cp /usrdata/simpleadmin/systemd/* /lib/systemd/system
systemctl daemon-reload

# Link systemd files
ln -s /lib/systemd/system/simpleadmin_httpd.service /lib/systemd/system/multi-user.target.wants/
ln -s /lib/systemd/system/simpleadmin_generate_status.service /lib/systemd/system/multi-user.target.wants/
ln -s /lib/systemd/system/ttl-override.service /lib/systemd/system/multi-user.target.wants/

# Remount readonly
mount -o remount,ro /

# Start Services
systemctl start simpleadmin_generate_status
systemctl start simpleadmin_httpd
systemctl start ttl-override
