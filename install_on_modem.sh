#!/bin/bash

#
# Installs AT Telnet Daemon and Simple Admin
#

read -p "Do you want to download AT Telnet Daemon and Simple Admin (yes/no) " yn

case $yn in
	yes ) echo ok, we will proceed;;
	no ) echo exiting...;
		exit;;
	* ) echo invalid response;
		exit 1;;
esac


# Download
cd /tmp
wget https://github.com/iamromulan/quectel-rgmii-simpleadmin-at-telnet-daemon/archive/refs/heads/main.zip

# Unzip
unzip main.zip
cp -R quectel-rgmii-simpleadmin-at-telnet-daemon-main* simpleadminattelnetdaemon/


read -p "Do you want to Install AT Telnet Daemon (yes/no) " yn

case $yn in
	yes ) echo ok, we will proceed;;
	no ) echo exiting...;
		exit;;
	* ) echo invalid response;
		exit 1;;
esac


# Copy over to /usrdata
cp -R /tmp/simpleadminattelnetdaemon/attelnetdaemon/at-telnet /usrdata/
cp -R /tmp/simpleadminattelnetdaemon/attelnetdaemon/micropython /usrdata/

# Chmod execute
chmod +x /usrdata/micropython/micropython /usrdata/at-telnet/modem-multiclient.py /usrdata/at-telnet/socat-armel-static /usrdata/at-telnet/picocom

# Remount
mount -o remount,rw /

# Copy systemd init files & reload
cp /usrdata/at-telnet/systemd_units/*.service /lib/systemd/system
systemctl daemon-reload

# Link systemd files
ln -s /lib/systemd/system/at-telnet-daemon.service /lib/systemd/system/multi-user.target.wants/
ln -s /lib/systemd/system/socat-smd11.service /lib/systemd/system/multi-user.target.wants/
ln -s /lib/systemd/system/socat-smd11-to-ttyIN.service /lib/systemd/system/multi-user.target.wants/
ln -s /lib/systemd/system/socat-smd11-from-ttyIN.service /lib/systemd/system/multi-user.target.wants/

# Remount readonly
mount -o remount,ro /

# Start Services
systemctl start socat-smd11
sleep 2s
systemctl start socat-smd11-to-ttyIN
systemctl start socat-smd11-from-ttyIN
systemctl start at-telnet-daemon


read -p "Do you want to install Simple Admin (yes/no) " yn

case $yn in
	yes ) echo ok, we will proceed;;
	no ) echo exiting...;
		exit;;
	* ) echo invalid response;
		exit 1;;
esac


# Copy over to /usrdata
cp -R /tmp/simpleadminattelnetdaemon/simpleadmin /usrdata/

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
