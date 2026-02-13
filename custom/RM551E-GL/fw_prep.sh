#!/bin/ash

# Define toolkit paths
GITUSER="iamromulan"
GITREPO="quectel-rgmii-toolkit"
GITTREE="SDXPINN"
GITMAINTREE="SDXPINN"
GITDEVTREE="development-SDXPINN"


# Function to remount file system as read-write
remount_rw() {
    mount -o remount,rw /
}

# Function to remount file system as read-only
remount_ro() {
    mount -o remount,ro /
}

prep_sysfs() {
	remount_rw
	echo "Unmounting /etc from usrdata"
	umount -lf /etc
	echo "Starting phase 1 prep"
	cd /tmp
	# Check if /etc/opkg.conf has a line containing "option overlay_root /overlay" and remove it if it exists
    	echo "Lets be sure your opkg config isn't using the old overlay"
    	if grep -q "option overlay_root /overlay" /etc/opkg.conf; then
        	echo "Removing 'option overlay_root /overlay' from /etc/opkg.conf"
        	sed -i '/option overlay_root \/overlay/d' /etc/opkg.conf
    	else
       	 echo "'option overlay_root /overlay' not found in /etc/opkg.conf, no changes made"
    	fi

	curl -O https://raw.githubusercontent.com/$GITUSER/$GITREPO/$GITTREE/opkg-feed/sdxpinn-patch_2.7_all.ipk
    	opkg install ./sdxpinn-patch_2.7_all.ipk
	opkg update
    	echo -e "\e[92m"
	echo "iamromulan's ipk/opkg repo added!"
    	echo "Installing basic packages..."
	opkg install atinout luci-app-atinout-mod mc-skins sdxpinn-console-menu luci-app-ttyd kmod-wireguard
    	echo "Patching default Quectel login binary..."
        echo -e "\e[0m"
	# Get rid of the Quectel Login Binary
	opkg install shadow-login
	mv /bin/login /bin/login.old
	cp /usr/bin/login /bin/login
	# Pre-set root password as iamromulan
	echo -e "iamromulan\niamromulan" | passwd root

    # Check and download /etc/init.d/dropbear if missing
    [ -f /etc/init.d/dropbear ] || { 
        curl -o /etc/init.d/dropbear https://raw.githubusercontent.com/$GITUSER/$GITREPO/$GITTREE/missing/dropbear &&
        chmod +x /etc/init.d/dropbear; 
    }

    # Check and download /etc/init.d/uhttpd if missing
    [ -f /etc/init.d/uhttpd ] || { 
        curl -o /etc/init.d/uhttpd https://raw.githubusercontent.com/$GITUSER/$GITREPO/$GITTREE/missing/uhttpd &&
        chmod +x /etc/init.d/uhttpd; 
    }


	service uhttpd enable
	service dropbear enable
	service uhttpd start
	service dropbear start
	
	# Set system hostname and timezone
	echo "Setting Hostname to RM551E-GL and time zone to Indianapolis"
	cp /usrdata/etc/config/system /etc/config/system
	uci set system.@system[0].hostname='RM551E-GL'
	uci set system.@system[0].zonename='America/Indiana/Indianapolis'
	uci set system.@system[0].timezone='EST5EDT,M3.2.0,M11.1.0'
	uci commit system
	service system reload
	
    	echo "Copying needed files to usrdata etc"
    	cp -rf /etc/opkg/* /usrdata/etc/opkg/
    	cp -f /etc/opkg.conf /usrdata/etc/opkg.conf
    	cp -f /etc/config/system /usrdata/etc/config/system
    	
    	echo "Stage 1 sysfs-prep complete!"
    	echo "Luci and Dropbear are now running."
    	echo "You may now make additional edits before final sysfs prep."
    	echo "Visit https://github.com/iamromulan for more!"
    	echo -e "\e[0m"
}

prep_final_sysfs() {
echo "Begin Final sysfs prep"
remount_rw
opkg update

echo "Arming first-boot init"
# Install first boot init
opkg install sdxpinn-firstboot

echo "Installing mount-fix"
mount -o bind /usrdata/etc /etc
sleep 1
opkg install sdxpinn-mount-fix
mount -o remount,rw /real_rootfs
cp -rfP /usrdata/rootfs/usr/lib/opkg/* /real_rootfs/usr/lib/opkg/
umount -lf /etc
echo "Creating a temp /etc overlay for use with the usrdata image"
mkdir /usrdata/tmp_etc
mkdir /usrdata/tmp_etc_work
mount -t overlay overlay -o lowerdir=/etc,upperdir=/usrdata/tmp_etc,workdir=/usrdata/tmp_etc_work /etc

echo "Stage 2 sysfs-prep complete!"
echo "You may now continue to make edits, these will be part of /usrdata/rootfs and /usrdata/tmp_etc though."
echo "These edits will be captured later (option 4) into /usrdata/usrdata.tar.gz so you add them to usrdata.ubi"
echo "Visit https://github.com/iamromulan for more!"

}

prep_usrdata() {
	echo "Installing larger Packages part of /usrdata"
	opkg update
	# opkg install things you want that are too large to be part of the main sysfs.ubi
	# Keep in mind AT+QCFG="resetfactory" will remove anything inside of usrdata
	
}

capture() {
    	echo -e "\e[92m"
    	#For R01
	#dd if=/dev/mtd35 of=/usrdata/sysfs.ubi bs=4096
	#For R02
	echo "Capturing MTD block 55 to /usrdata/sysfs.ubi"
	dd if=/dev/mtd55 of=/usrdata/sysfs.ubi bs=4096
	#For edits after mount-fix is in place
	echo "Capturing directories needed for usrdata.ubi to /usrdata/usrdata.tar.gz"
    	tar -czf /usrdata/usrdata.tar.gz /usrdata/rootfs /usrdata/rootfs-workdir /usrdata/tmp_etc
    	echo "Capture complete!"
    	echo "Now do..."
    	echo "adb pull /usrdata/sysfs.ubi"
    	echo "adb pull /usrdata/usrdata.tar.gz"
    	echo "In your usrdata.ubi place rootfs, rootfs-workdir, and tmp_etc inside."
    	echo "Then Rename tmp_etc to etc and you are all set."
    	echo "Visit https://github.com/iamromulan for more!"
    	echo -e "\e[0m"
}

# Main menu
while true; do
echo "                                  :@@@@-                     "
echo "                                      -@@@@#.                "
echo "      .+-                                #@@@@%.+@-          "
echo "    -@*@*@%                                @@@@@::@@=        "
echo "    .@@@@@:                                :@@@@@ =@@@..%=   "
echo "      .%-                                  -@@@@@:=@@@@  @@# "
echo "      .*-            .@@@@@@@@@@=.         @@@@@@ @@@@@  @@@:"
echo "                        -@@@@@@@@@@@@@@@..@@@@@@.-@@@@@ .@@@-"
echo "                           =@@@@@@@@*  .@@@@@@. @@@@@@..@@@@-"
echo "                            @@@@@@:.-@@@@@@.  @@@@@@= %@@@@@."
echo "                           %@@. =@@@@@*.  +@@@@@@%.-@@@@@@%  "
echo "                          =@.+@@@@@. -@@@@@@@*.:@@@@@@@*.    "
echo "                          ..@@@@= .@@@@@@: #@@@@@@@:         "
echo "                           .@@@.  @@@@.:@@@@+.               "
echo "                            :@@@  %@@..@@#.    *@            "
echo "                       =@@@@@@.*@- :@%  @* =@:=@#            "
echo "                      .@@.  @@-%@:      .%@@*@@%.            "
echo "                                  .*@@@:=@@@@:               "
echo "                             #@@@@: =@@@@@-                  "
echo "                         -@@@@@  @@@@@@%                     "
echo "                        :@@@@# =@@@@@@%                      "
echo "                        *@@@@  @@@@@@@.                      "
echo "                         #@@@. @@@@@@*                       "
echo "                                *@@@@@@                      "
echo "                                  .@@@@@@.                   "
echo "                                      .=@@@@@-               "


    echo -e "\e[92m"
    echo "Firmware prep script for SDXPINN"
    echo "Visit https://github.com/iamromulan for more!"
    echo -e "\e[0m"
    echo "Select an option:"
    echo -e "\e[0m"
    echo -e "\e[96m1) Prep-sysfs\e[0m" # Cyan
    echo -e "\e[93m2) Final Prep-sysfs\e[0m" # Yellow
    echo -e "\e[92m3) Prep-usrdata\e[0m" # Green
    echo -e "\e[94m4) Capture\e[0m" # Light Blue
    echo -e "\e[93m5) Exit\e[0m" # Yellow (repeated color for exit option)
    read -p "Enter your choice: " choice

    case $choice in
        1) prep_sysfs ;;
        2) prep_final_sysfs ;;
        3) prep_usrdata ;;
        4) capture ;;   
        5) echo -e "\e[1;32mGoodbye!\e[0m"; break ;;
        *) echo -e "\e[1;31mInvalid option\e[0m" ;;
    esac
done


