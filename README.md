# AT Telnet Daemon and Simple Admin combo installer/updater/uninstaller
**ONLY FOR THE QUECTEL RM520N-GL (for now)**
#### [JUMP TO COMBO INSTALLER](#installation-automated)
**Currently:** This will install or if already installed, update or remove a Combination of [AT Telnet Daemon](https://github.com/natecarlson/quectel-rgmii-at-command-client/tree/main/at_telnet_daemon)  and; [Simpleadmin](https://github.com/iamromulan/quectel-rgmii-simpleadmin)

**My goal** is for this to also install a settable and changeable daily reboot, and provide an interactive AT shell within adb shell/directly in the root shell. The .sh these is based on will also be available. (Hopefully coming soon)
## Screenshots
![Home Page](https://raw.githubusercontent.com/iamromulan/quectel-rgmii-simpleadmin-at-telnet-daemon/main/iamromulansimpleindex.png)
![AT Commands](https://raw.githubusercontent.com/iamromulan/quectel-rgmii-simpleadmin-at-telnet-daemon/main/iamromulanatcommands.png)
![enter image description here](https://raw.githubusercontent.com/iamromulan/quectel-rgmii-simpleadmin-at-telnet-daemon/main/iamromulansimpleTTL.png)
## Installation Automated

> :warning: Your modem must already be connected to the internet for this to work

Script will present a list of options:

 1.  AT Telnet Daemon
 2.  Simple Admin
 3. Exit


If it is not installed and you press 1 or 2 it will install. If it is, it will prompt to uninstall or update. 

You can copy/paste this into a command prompt on a system with adb installed. If you don't have adb follow the directions in my main [RGMII Guide](https://github.com/iamromulan/quectel-rgmii-configuration-notes#using-adb)
```bash
adb shell wget -P /tmp https://raw.githubusercontent.com/iamromulan/quectel-rgmii-simpleadmin-at-telnet-daemon/main/install_on_modem.sh
adb shell chmod +x /tmp/install_on_modem.sh
adb shell sh /tmp/install_on_modem.sh
```
If you have trouble downloading the file make sure your modem is connected to a cellular network.

If you already had all your proper settings set and you just flashed the firmware, more than likely running AT+QMAPWAC=1 and rebooting will fix that. You can do it with adb as well like this:  

    adb shell "echo -e 'AT+QMAPWAC=1 \r' > /dev/smd7"
    adb shell reboot


====================================================

## Acknowledgements
Thanks to the work of [Nate Carlson](https://github.com/natecarlson) (Telnet Deamon, Original RGMII Notes), [aesthernr](https://github.com/aesthernr) (Original simpleadmin), and [rbflurry](https://github.com/rbflurry/) (Fixing simpleadmin not functioning) we can install these! The Telnet Deamon is a Telnet to AT command server. With it, you can connect with a Telenet client like PuTTY on port 5000 to the modems gateway IP (Normally 192.168.225.1) and send AT commands over Telnet! Simpleadmin is a simple web interface you'll be able to access using the modems gateway IP address. You can see some basic signal stats, send AT commands from the browser, and change your TTL directly on the modem. By default this will be on port 8080 so if you didn't change the gateway IP address you'd go to http://192.168.225.1:8080/ and you'd find what you see in the [Screenshots](#screenshots) section.

Simpleadmin heavily uses the AT Command Parsing Scripts (Basically a copy with minor tweaks) of Dairyman's Rooter Source https://github.com/ofmodemsandmen/ROOterSource2203


