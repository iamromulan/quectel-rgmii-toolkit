# RGMII Toolkit
**ORIGINALLY FOR THE QUECTEL RM520N-GL, However, People are saying this will work on all M.2 RMxxx modems**
#### [JUMP TO HOW TO USE](#how-to-use)
**Currently:** This will install or if already installed, update or remove a Combination of [AT Telnet Daemon](https://github.com/natecarlson/quectel-rgmii-at-command-client/tree/main/at_telnet_daemon)  and; [Simpleadmin](https://github.com/iamromulan/quectel-rgmii-simpleadmin). This will also allow you to set a daily reboot timer and send AT commands easily. 

**My goal** is for this to also include any new useful scripts or software for this modem and others that support RGMII mode.
## Screenshots

![Home Page](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/iamromulansimpleindex.png?raw=true)
![AT Commands](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/iamromulanatcommands.png?raw=true)
![TTL](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/iamromulansimpleTTL.png?raw=true)
![Toolkit](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/iamromulantoolkit.png?raw=true)


## How to Use
**To run the Toolkit:**
 - Open ADB & Fastboot++ covered in [Using ADB](https://github.com/iamromulan/quectel-rgmii-configuration-notes?tab=readme-ov-file#unlocking-and-using-adb) or just use adb
 - Make sure your modem is connected by USB to your computer
 - Run `adb devices` to make sure your modem is detected by adb
 - Run `adb shell ping 8.8.8.8` to make sure the shell can access the internet. If you get an error, make sure the modem is connected to a cellular network and make sure `AT+QMAPWAC=1` as covered in the troubleshooting section: [I Can't get internet access from the Ethernet port (Common)](https://github.com/iamromulan/quectel-rgmii-configuration-notes/tree/main?tab=readme-ov-file#i-cant-get-internet-access-from-the-ethernet-port-common)
 - If you don't get an error you should be getting replies back endlessly, press `CTRL-C` to stop it.
 - Run the following commands 
```bash
adb shell wget -P /tmp https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/RMxxx_rgmii_toolkit.sh
adb shell chmod +x /tmp/RMxxx_rgmii_toolkit.sh
adb shell sh /tmp/RMxxx_rgmii_toolkit.sh
```
**After running that last command:**
![Toolkit](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/iamromulantoolkit.png?raw=true)

## Tailscale Installation and Config

> :warning: Your modem must already be connected to the internet for this to install
### Installation:
Open up the toolkit main menu and press 4 to enter the Tailscale menu

![Toolkit](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/tailscalemenu.png?raw=true)

**Press 1, wait for it to install. This is a very large file for the system so give it some time. Once done and it says tailscaled is started press 2 to configure it.**

![Toolkit](https://github.com/iamromulan/quectel-rgmii-configuration-notes/blob/main/images/tailscaleconfig.png?raw=true)

First time connecting you'll be given a link to login with
 - Press 1 to just connect only.
 - Press 2 to connect and enable SSH access (remote command line) over tailscale.
 - Press 3 to reconnect with SSH off while connected with SSH on
 - Press 4 to disconnect
 - Press 5 to Logout

**Important**

**You will want to go to your Tailscale DNS settings at https://login.tailscale.com/admin/dns and turn on Override local DNS and add a DNS provider to avoid loosing internet connectivity on your modem.** 

This happens because the Tailscale binary creates  `/etc/reslov.conf` to override the modems DNS to use the one from your Tailnet instead. If you don't have a public DNS you won't be able to use the internet. I use Cloudflare and Google. I will add an option to the Toolkit to connect with DNS off later, its on the hit list.

That's it! From another device running tailscale you should be able to access your modem through the IP assigned to it by your tailnet. To access SSH from another device on the tailnet, open a terminal/command prompt and type

    tailscale ssh root@(IP or Hostname)
IP or Hostname being the IP or hostname assigned to it in your tailnet

 - Note that your SSH client must be able to give you a link to sign in with upon connecting. That's how the session is authorized. Works fine in Windows CMD or on Android use JuiceSSH.
## Acknowledgements
Thanks to the work of [Nate Carlson](https://github.com/natecarlson) (Telnet Deamon, Original RGMII Notes), [aesthernr](https://github.com/aesthernr) (Original simpleadmin), and [rbflurry](https://github.com/rbflurry/) (Fixing simpleadmin not functioning) we can install these! The Telnet Deamon is a Telnet to AT command server. With it, you can connect with a Telenet client like PuTTY on port 5000 to the modems gateway IP (Normally 192.168.225.1) and send AT commands over Telnet! Simpleadmin is a simple web interface you'll be able to access using the modems gateway IP address. You can see some basic signal stats, send AT commands from the browser, and change your TTL directly on the modem. By default this will be on port 8080 so if you didn't change the gateway IP address you'd go to http://192.168.225.1:8080/ and you'd find what you see in the [Screenshots](#screenshots) section.

Simpleadmin heavily uses the AT Command Parsing Scripts (Basically a copy with minor tweaks) of Dairyman's Rooter Source https://github.com/ofmodemsandmen/ROOterSource2203

Tailscale was obtained through Tailscale's static build page. Since these modems have a 32-bit ARM processor on-board I used the arm package. https://pkgs.tailscale.com/stable/#static



