# ORIGINAL PROJECT PRESERVED HERE

# RGMII Toolkit
## Software deployment Toolkit for Quectel RM5xxx series 5G modems utilizing an m.2 to RJ45 adapter (RGMII)

Current Branch: **Main**

Please Fork and PR with/to [Development](https://github.com/iamromulan/quectel-rgmii-toolkit/tree/development) instead of main, it has the latest changes and is meant to be commits ahead of main for testing. :)

"Don't push to production 😂"

Fork development, and PR development to development :)




#### [JUMP TO HOW TO USE](#how-to-use)
**Currently:** This will allow you to install or if already installed, update, remove, or modify:
 - Simple Admin: A simple web interface for managing your Quectel m.2 modem through it's gateway address
	 - It will install socat-at-bridge: sets up ttyOUT and ttyOUT2 for AT commands. You'll be able to use the `atcmd` command as well for an interactive at command session from adb, ssh, or ttyd
	 - It will install simplefirewall: A simple firewall that blocks definable incoming ports and a TTL mangle option/modifier. As of now only the TTL is controllable through Simple Admin. You can edit port block options and TTL from the 3rd option in the toolkit
 - Tailscale: A magic VPN for accessing Simple Admin, SSH, and ttyd on the go. The Toolkit installs the Tailscale client directly to the modem and allows you to login and configure other settings. Head over to tailscale.com to sign up for a free account and learn more.
 - Schedule a Daily Reboot at a specified time
 - A fix for certain modems that don't start in CFUN=1 mode
 - Entware/OPKG: A package installer/manager/repo
	- Run `opkg help` to see how to use it
	- These packages are installable: https://bin.entware.net/armv7sf-k3.2/Packages.html
 - TTYd: A shell session right from your browser
	 - Currently this uses port 443 but SSL/TLS is not in use (http only for now)
	 - Entware/OPKG is required so it will install it if it isn't installed
	 - This will replace the stock Quectel login and passwd binaries with ones from entware

  

**My goal** is for this to also include any new useful scripts or software for this modem and others that support RGMII mode.
## Screenshots

![Toolkit](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/iamromulantoolkit.png?raw=true)
![Home Page](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/iamromulansimpleindex.png?raw=true)
![AT Commands](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/iamromulanatcommands.png?raw=true)

![AT Commands](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/iamromulansimplenetwork.png?raw=true)
![TTL](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/iamromulansimpleTTL.png?raw=true)

![TTL](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/iamromulanspeedtest.png?raw=true)



## How to Use
**To run the Toolkit:**
 - Open ADB & Fastboot++ covered in [Using ADB](https://github.com/iamromulan/quectel-rgmii-configuration-notes?tab=readme-ov-file#unlocking-and-using-adb) or just use adb
 - Make sure your modem is connected by USB to your computer
 - Run `adb devices` to make sure your modem is detected by adb
 - Run `adb shell ping 8.8.8.8` to make sure the shell can access the internet. If you get an error, make sure the modem is connected to a cellular network and make sure `AT+QMAPWAC=1` as covered in the troubleshooting section: [I Can't get internet access from the Ethernet port (Common)](https://github.com/iamromulan/quectel-rgmii-configuration-notes/tree/main?tab=readme-ov-file#i-cant-get-internet-access-from-the-ethernet-port-common)
 - If you don't get an error you should be getting replies back endlessly, press `CTRL-C` to stop it.
 - Simply Copy/Paste this into your Command Prompt/Shell 
```bash
adb shell "cd /tmp && wget -O RMxxx_rgmii_toolkit.sh https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/RMxxx_rgmii_toolkit.sh && chmod +x RMxxx_rgmii_toolkit.sh && ./RMxxx_rgmii_toolkit.sh" && cd /
```

**Or, if you want to stay in the modems shell when you are done**

```
adb shell
```
Then run
```
cd /tmp && wget -O RMxxx_rgmii_toolkit.sh https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/RMxxx_rgmii_toolkit.sh && chmod +x RMxxx_rgmii_toolkit.sh && ./RMxxx_rgmii_toolkit.sh && cd /
```
**You should see:**


![Toolkit](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/iamromulantoolkit.png?raw=true)

## Tailscale Installation and Config

> :warning: Your modem must already be connected to the internet for this to install
### Installation:
Open up the toolkit main menu and **press 4** to enter the Tailscale menu

![Toolkit](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/tailscalemenu.png?raw=true)

**Press 1, wait for it to install. This is a very large file for the system so give it some time.**

**Once done and it says Tailscale installed successfully press 2/enter to configure it.**

![Toolkit](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/tailscaleconfig.png?raw=true)

If you want to, enable the Tailscale Web UI on port 8088 for configuration from the browser later by **pressing 1/enter**.

To do it in the toolkit:
First time connecting you'll be given a link to login with
 - Press 3 to just connect only.
 - Press 4 to connect and enable SSH access (remote command line) over tailscale.
 - Press 5 to reconnect with SSH off while connected with SSH on
 - Press 6 to disconnect
 - Press 7 to Logout

That's it! From another device running tailscale you should be able to access your modem through the IP assigned to it by your tailnet. To access SSH from another device on the tailnet, open a terminal/command prompt and type

    tailscale ssh root@(IP or Hostname)
IP or Hostname being the IP or hostname assigned to it in your tailnet

 - Note that your SSH client must be able to give you a link to sign in with upon connecting. That's how the session is authorized. Works fine in Windows CMD or on Android use JuiceSSH.
### Entware/OPKG installation

 - After installing, the `opkg` command will work
 - You can run `opkg list` to see a list of installable packages, or head over to  https://bin.entware.net/armv7sf-k3.2/Packages.html
 - Everything opkg does is installed to /opt
 - `/opt` is actually located at `/usrdata/opt` to save space but is   
   mounted at `/opt`
 - To properly use entware/opkg run the `login` command first if using adb to use stufff installed by entware/opkg
 - Be aware of space and CPU limits, run `dfc` to see what the available space in `/opt` is. Run `htop` to see CPU usage and memory usage

### TTYd installation

 - This listens on port 443 for http requests (no SSL/TLS yet)
 - This will automaticly install entware and patch the login and passwd binaries with ones from entware\so you can login
 - It will ask you to set a password for the `root` user account
 - TTYd doesn't seem to be too mobile friendly for now but I optimized it the best i could for now so it is at least usable through a smartphone browser. Hopefully the startup script can be improved even more later. Some people have a better experience depending on mobile browser

## Acknowledgements
### GitHub Users/Individuals:
Thank You to: 

[Nate Carlson](https://github.com/natecarlson) for the Original Telnet Deamon/socat bridge usage and the Original RGMII Notes

[aesthernr](https://github.com/aesthernr)  for creating the Original Simple Admin

[rbflurry](https://github.com/rbflurry/) for inital Simple Admin fixes

[dr-dolomite](https://github.com/dr-dolomite) for some major stat page improvements and this repos first approved external PR!

### Existing projects:
Simpleadmin heavily uses the AT Command Parsing Scripts (Basically a copy with new changes and tweaks) of Dairyman's Rooter Source https://github.com/ofmodemsandmen/ROOterSource2203

Tailscale was obtained through Tailscale's static build page. Since these modems have a 32-bit ARM processor on-board I used the arm package. https://pkgs.tailscale.com/stable/#static

Entware/opkg was obtained through [Entware's wiki](https://github.com/Entware/Entware/wiki/Alternative-install-vs-standard) and the installer heavily modified by [iamromulan](https://github.com/iamromulan) for use with Quectel modems

TTYd was obtained from the [TTYd Project](https://github.com/tsl0922/ttyd)
