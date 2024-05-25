#!/bin/bash

# Define constants
GITUSER="iamromulan"
GITTREE="development"
DIR_NAME="simpleadmin"
SERVICE_FILE="/lib/systemd/system/install_simpleadmin.service"
SERVICE_NAME="install_simpleadmin"
TMP_SCRIPT="/tmp/install_simpleadmin.sh"
LOG_FILE="/tmp/install_simpleadmin.log"
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/usrdata/root/bin

# Tmp Script dependent constants 
SIMPLE_ADMIN_DIR="/usrdata/simpleadmin"
# Function to remount file system as read-write
remount_rw() {
    mount -o remount,rw /
}

# Function to remount file system as read-only
remount_ro() {
    mount -o remount,ro /
}

# Installation Prep
remount_rw
systemctl daemon-reload
rm $SERVICE_FILE > /dev/null 2>&1
rm $SERVICE_NAME > /dev/null 2>&1

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

GITUSER="iamromulan"
GITTREE="development"
SIMPLE_ADMIN_DIR="/usrdata/simpleadmin"
export HOME=/usrdata/root
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/usrdata/root/bin

# Function to remount file system as read-write
remount_rw() {
    mount -o remount,rw /
}

# Function to remount file system as read-only
remount_ro() {
    mount -o remount,ro /
}
remount_rw
uninstall_simpleadmin() {
	echo "Uninstalling Simpleadmin..."
		
	# Check if Lighttpd service is installed and remove it if present
	if [ -f "/lib/systemd/system/lighttpd.service" ]; then
		echo "Lighttpd detected, uninstalling Lighttpd webserver and its modules..."
		systemctl stop lighttpd
		rm -f /lib/systemd/system/lighttpd.service
		opkg --force-remove --force-removal-of-dependent-packages remove lighttpd-mod-authn_file lighttpd-mod-auth lighttpd-mod-cgi lighttpd-mod-openssl lighttpd-mod-proxy lighttpd
	fi
	echo -e "\e[1;34mUninstalling simpleadmin content...\e[0m"
	systemctl stop simpleadmin_generate_status
	systemctl stop simpleadmin_httpd
	rm -f /lib/systemd/system/simpleadmin_httpd.service
	rm -f /lib/systemd/system/simpleadmin_generate_status.service
	systemctl daemon-reload
	
	echo -e "\e[1;34mUninstalling ttyd...\e[0m"
    systemctl stop ttyd
    rm -rf /usrdata/ttyd
	rm -rf "$SIMPLE_ADMIN_DIR"
    rm -f /lib/systemd/system/ttyd.service
    rm -f /lib/systemd/system/multi-user.target.wants/ttyd.service
    rm -f /bin/ttyd
    echo -e "\e[1;32mttyd has been uninstalled.\e[0m"

    echo "Uninstallation process completed."
}

install_lighttpd() {
	# Check for simpleadmin_httpd service and remove if exists
    if [ -f "/lib/systemd/system/simpleadmin_httpd.service" ]; then
        systemctl stop simpleadmin_httpd
        rm /lib/systemd/system/simpleadmin_httpd.service
        rm /lib/systemd/system/multi-user.target.wants/simpleadmin_httpd.service
    fi

    /opt/bin/opkg install sudo lighttpd lighttpd-mod-auth lighttpd-mod-authn_file lighttpd-mod-cgi lighttpd-mod-openssl lighttpd-mod-proxy
    # Ensure rc.unslung doesn't try to start it
    # Dynamically find and remove any Lighttpd-related init script
    for script in /opt/etc/init.d/*lighttpd*; do
        if [ -f "$script" ]; then
            echo "Removing existing Lighttpd init script: $script"
            rm "$script" # Remove the script if it contains 'lighttpd' in its name
        fi
    done
    systemctl stop lighttpd
    echo -e "\033[0;32mInstalling/Updating Lighttpd...\033[0m"
    mkdir -p "$SIMPLE_ADMIN_DIR"
    wget -O "$SIMPLE_ADMIN_DIR/lighttpd.conf" https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/lighttpd.conf
    wget -O "/lib/systemd/system/lighttpd.service" https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/systemd/lighttpd.service
    ln -sf "/lib/systemd/system/lighttpd.service" "/lib/systemd/system/multi-user.target.wants/"
    echo "www-data ALL = (root) NOPASSWD: /usr/sbin/iptables, /usr/sbin/ip6tables, /usrdata/simplefirewall/ttl-override, /bin/echo, /bin/cat" > /opt/etc/sudoers.d/www-data

    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=US/ST=MI/L=Romulus/O=RMIITools/CN=localhost" \
        -keyout $SIMPLE_ADMIN_DIR/server.key -out $SIMPLE_ADMIN_DIR/server.crt
    systemctl daemon-reload
    systemctl start lighttpd
    
    echo -e "\033[0;32mLighttpd installation/update complete.\033[0m"
}

install_simpleadmin() {
remount_rw
echo -e "\e[1;31m2) Installing simpleadmin from the $GITTREE branch\e[0m"
			mkdir $SIMPLE_ADMIN_DIR
			mkdir $SIMPLE_ADMIN_DIR/systemd
			mkdir $SIMPLE_ADMIN_DIR/script
    		mkdir $SIMPLE_ADMIN_DIR/console
			mkdir $SIMPLE_ADMIN_DIR/console/menu
			mkdir $SIMPLE_ADMIN_DIR/console/services
			mkdir $SIMPLE_ADMIN_DIR/console/services/systemd
      		mkdir $SIMPLE_ADMIN_DIR/www
			mkdir $SIMPLE_ADMIN_DIR/www/cgi-bin
			mkdir $SIMPLE_ADMIN_DIR/www/css
    		mkdir $SIMPLE_ADMIN_DIR/www/js
            cd $SIMPLE_ADMIN_DIR/systemd
            wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/systemd/lighttpd.service
			sleep 1
			cd $SIMPLE_ADMIN_DIR/script
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/script/ttl_script.sh
			sleep 1
			cd $SIMPLE_ADMIN_DIR/console
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/console/.profile
			sleep 1
			cd $SIMPLE_ADMIN_DIR/console/menu
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/console/menu/start_menu.sh
			ln -f $SIMPLE_ADMIN_DIR/console/menu/start_menu.sh /usrdata/root/bin/menu
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/console/menu/sfirewall_settings.sh
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/console/menu/start_menu.sh
			sleep 1
			cd $SIMPLE_ADMIN_DIR/www
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/deviceinfo.html
   			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/favicon.ico
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/index.html
    		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/network.html
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/settings.html
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/sms.html
   			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/logout.html
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/scanner.html
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/watchcat.html
			sleep 1
			cd $SIMPLE_ADMIN_DIR/www/js
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/js/alpinejs.min.js
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/js/bootstrap.bundle.min.js
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/js/dark-mode.js
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/js/generate-freq-box.js
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/js/parse-settings.js
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/js/populate-checkbox.js
    		sleep 1
    		cd $SIMPLE_ADMIN_DIR/www/css
    		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/css/bootstrap.min.css
      		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/css/styles.css
			sleep 1
			cd $SIMPLE_ADMIN_DIR/www/cgi-bin
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/cgi-bin/get_atcommand
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/cgi-bin/get_ping
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/cgi-bin/get_sms
    		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/cgi-bin/get_ttl_status
      		wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/cgi-bin/set_ttl
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/cgi-bin/send_sms
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/cgi-bin/get_uptime
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/cgi-bin/get_watchcat_status
			wget https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/www/cgi-bin/set_watchcat
			sleep 1
			cd /
            chmod +x $SIMPLE_ADMIN_DIR/www/cgi-bin/*
			chmod +x $SIMPLE_ADMIN_DIR/script/*
			chmod +x $SIMPLE_ADMIN_DIR/console/menu/*
			chmod +x $SIMPLE_ADMIN_DIR/console/.profile
			cp -f $SIMPLE_ADMIN_DIR/console/.profile /usrdata/root/.profile
			chmod +x /usrdata/root/.profile
            cp -rf $SIMPLE_ADMIN_DIR/systemd/* /lib/systemd/system
			sleep 1
            systemctl daemon-reload
			sleep 1
}
install_ttyd() {
    echo -e "\e[1;34mStarting ttyd installation process...\e[0m"
    cd $SIMPLE_ADMIN_DIR/console
    curl -L -o ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.armhf && chmod +x ttyd
    wget "https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/console/ttyd.bash" && chmod +x ttyd.bash
    cd $SIMPLE_ADMIN_DIR/systemd/
	wget "https://raw.githubusercontent.com/$GITUSER/quectel-rgmii-toolkit/$GITTREE/simpleadmin/systemd/ttyd.service"
    cp -f $SIMPLE_ADMIN_DIR/systemd/ttyd.service /lib/systemd/system/
    ln -sf /usrdata/simpleadmin/ttyd /bin
    
    # Enabling and starting ttyd service
    systemctl daemon-reload
    ln -sf /lib/systemd/system/ttyd.service /lib/systemd/system/multi-user.target.wants/
    systemctl start ttyd
    if [ "$?" -ne 0 ]; then
        echo -e "\e[1;31mFailed to start ttyd service. Please check the systemd service file and ttyd binary.\e[0m"
        exit 1
    fi

    echo -e "\e[1;32mInstallation Complete! ttyd server is up.\e[0m"
}
uninstall_simpleadmin
install_lighttpd
install_simpleadmin
install_ttyd
remount_ro
exit 0
EOF

# Make the temporary script executable
chmod +x "$TMP_SCRIPT"

# Reload systemd to recognize the new service and start the update
systemctl daemon-reload
systemctl start $SERVICE_NAME
