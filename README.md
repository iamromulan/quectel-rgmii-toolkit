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
## Advanced/Beta

### Entware/OPKG installation
Recently I was able to successfully install opkg, the same package manager that OpenWRT has! This was acheved through [Entware!](https://github.com/Entware/Entware/wiki) 
I modified [this](https://bin.entware.net/armv7sf-k3.2/installer/generic.sh)  generic installer to include a few tweaks to make it more compatible and automated for Quectel modems. In my testing I used the RM521F-GL and RM502Q-AE but it should work for others as long as you have enough space and a /usrdata mount point to work with.

#### To install Entware/OPKG
Simply run this command from adb shell or SSH shell

    wget -O- https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/main/installentware.sh | sh

It isn't perfect yet so here's what you gotta know about going into it

 - After installing, the `opkg` command will work
 - You can run `opkg list` to see a list of installable packages
 - Everything opkg does is installed to /opt
 - `/opt` is actually located at `/usrdata/opt` to save space but is   
   mounted at `/opt`
 - Anything `opkg` installs will not be available in the system path by 
   default but you can get around this either:

#### Temporarily:
 Run this at the start of each adb shell or SSH shell session

    export PATH=/opt/bin:/opt/sbin:$PATH

#### Permanently:
Symbolic linking each binary installed by the package to `/bin` and `/sbin` from `/opt/bin` and `/opt/sbin`
For example, if you were to install zerotier:

    opkg install zerotier
    ln -sf /opt/bin/zerotier-one /bin
    ln -sf /opt/bin/zerotier-cli /bin
    ln -sf /opt/bin/zerotier-idtool /bin

Now you can run those 3 binaries from the shell anytime since they are linked in a place already part of the system path.

## Acknowledgements
Thanks to the work of [Nate Carlson](https://github.com/natecarlson) (Telnet Deamon, Original RGMII Notes), [aesthernr](https://github.com/aesthernr) (Original simpleadmin), and [rbflurry](https://github.com/rbflurry/) (Fixing simpleadmin not functioning) we can install these! The Telnet Deamon is a Telnet to AT command server. With it, you can connect with a Telenet client like PuTTY on port 5000 to the modems gateway IP (Normally 192.168.225.1) and send AT commands over Telnet! Simpleadmin is a simple web interface you'll be able to access using the modems gateway IP address. You can see some basic signal stats, send AT commands from the browser, and change your TTL directly on the modem. By default this will be on port 8080 so if you didn't change the gateway IP address you'd go to http://192.168.225.1:8080/ and you'd find what you see in the [Screenshots](#screenshots) section.

Simpleadmin heavily uses the AT Command Parsing Scripts (Basically a copy with minor tweaks) of Dairyman's Rooter Source https://github.com/ofmodemsandmen/ROOterSource2203

Tailscale was obtained through Tailscale's static build page. Since these modems have a 32-bit ARM processor on-board I used the arm package. https://pkgs.tailscale.com/stable/#static

Entware/opkg was obtained through [Entware's wiki](https://github.com/Entware/Entware/wiki/Alternative-install-vs-standard)
