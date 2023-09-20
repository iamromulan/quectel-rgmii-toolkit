# Simple Web Admin Interface for Quectel Modem using RJ45 Boards
Simple Admin / Monitoring web UI for Quectel modems that are connected via a RGMII Ethernet interface (aka a "RJ45 to M.2" or "Ethernet to M.2" adapter board). Such as <a href="https://www.aliexpress.us/item/3256804672394777.html">Generic RJ45 Board</a> or the <a href="https://www.aliexpress.us/item/3256805527880876.html">MCUZone board</a>

This heavily relies on the work of <a href="https://github.com/natecarlson/">Nate</a> building on top of <a href="https://github.com/natecarlson/quectel-rgmii-at-command-client/tree/main/at_telnet_daemon">at_telnet_daemon</a> which is required prerequisite install before this will work.

## Warning
Working in ADB is complex and running additional items not from the factory can be dangerous. Please run this with caution and be warned this comes "AS IS" without warranty and I will not be responsible for anything that happens in result of using this project.

## Tested Quectel Modems
Currently Only the RM520 has been tested and determined working, I will be doing additional tests the For the RM502.

If you are able to test on other modems and get it working, feel free to PR.

## Requirements
* ADB access to your modem
* Installing Nate's at_telnet_daemon

## Installation Automated
Script will do everything but setup Nate's at_telnet_daemon
```bash
adb shell wget -P /tmp https://raw.githubusercontent.com/rbflurry/quectel-rgmii-simpleadmin/main/install_on_modem.sh
adb shell chmod +x /tmp/install_on_modem.sh
adb shell sh /tmp/install_on_modem.sh
```

## Installation DIY
```bash
adb push quectel-rgmii-simpleadmin /usrdata/simpleadmin
adb shell chmod +x /usrdata/simpleadmin/scripts/* /usrdata/simpleadmin/www/cgi-bin/* /usrdata/simpleadmin/ttl/ttl-override
adb shell mount -o remount,rw /
adb shell cp /usrdata/simpleadmin/systemd/* /lib/systemd/system
adb shell systemctl daemon-reload
adb shell ln -s /lib/systemd/system/simpleadmin_httpd.service /lib/systemd/system/multi-user.target.wants/
adb shell ln -s /lib/systemd/system/simpleadmin_generate_status.service /lib/systemd/system/multi-user.target.wants/
adb shell ln -s /lib/systemd/system/ttl-override.service /lib/systemd/system/multi-user.target.wants/
adb shell mount -o remount,ro /
adb shell systemctl start simpleadmin_generate_status
adb shell systemctl start simpleadmin_httpd
adb shell systemctl start ttl-override
```

## Access Simple Admin
This will launch on port 8080 by default, you are welcome to change that if you do not desire to use the QCMAP_CLI in the simpleadmin_generate_status.service file.

Launch your browser to http://192.168.225.1:8080

The backend and frontend will automatically update every 30 seconds. Will implement ways to change the update time in the future but will need some additional users testing to see if this is stable enough.

### Access Notice!
This is not password protected at the moment, please be careful if you are not CGNAT and have a public IP as this will be available to the public

## Note About TTL Mod
If you are currently using Nate's TTL-Override, please remove that systemd service

```bash
adb shell /etc/initscripts/ttl-override stop
adb shell mount -o remount,rw /
adb shell rm -v /etc/initscripts/ttl-override /lib/systemd/system/ttl-override.service /lib/systemd/system/multi-user.target.wants/ttl-override.service
adb shell mount -o remount,ro /
adb shell systemctl daemon-reload
```

## Acknowledgements
This heavily uses the AT Command Parsing Scripts (Basically a copy with minor tweaks) of Dairyman's Rooter Source https://github.com/ofmodemsandmen/ROOterSource2203
