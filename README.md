# RC PCIe Toolkit
Software deployment Toolkit for Quectel RM5xxx series 5G modems utilizing an m.2 to RJ45 adapter (RC PCIe)

Example: https://rework.network/collections/lte-home-gateway/products/5g2phy

Current Branch: **SDXPINN**

YouTube Video: [Watch](https://www.youtube.com/watch?v=dh7dbEyHwiY)

This is a work in progress branch for early development for the RM551E-GL modem (Will probably work on the 550 as well)

# The below commands will download the beta/work in progress toolkit only for RM55x modems/SDXPINN platform

# Current state:
The toolkit will do the following:
1. AT Commands
	- Needs tested.
	
2. Install sdxpinn-mount-fix/run me after a flash!
	- Installs sdxpinn-mount-fix so you can have a usable filesystem.
 	- You won't get far without this installed
	
	
3. TTL Setup
	- Will allow you to set a TTL value

4. Install Basic Packages/enable luci/add iamromulan's feed to opkg
   	- Adds this repo as a source for opkg/software to get packages
   	- Installs the public key for this repo
   	- Installs a few basic packages: atinout luci-app-atinout-mod sdxpinn-console-menu shadow-login luci-app-ttyd mc mc-skins
   	- Starts and enables the SSH server and uhttpd web server (Luci)

5. Set root password
	- Runs the passwd utility so you can set your password for root

6. Tailscale Management
	- Will let you install tailscale
		- Installs my updated ipks
	- Will let you configure tailscale 
		- No web server yet

7. Install Speedtest.net CLI app (speedtest command)
	- Will install the speedtest command (speedtest.net test) 
	- After install type speedtest to use it

## How to Use
**To run the Toolkit:**
 - Open ADB & Fastboot++ covered in [Using ADB](https://github.com/iamromulan/quectel-rgmii-configuration-notes?tab=readme-ov-file#unlocking-and-using-adb) or just use adb
 - Make sure your modem is connected by USB to your computer
 - Run `adb devices` to make sure your modem is detected by adb
 - Run `adb shell ping 8.8.8.8` to make sure the shell can access the internet. If you get an error, make sure the modem is connected to a cellular network and make sure `AT+QMAPWAC=1` as covered in the troubleshooting section: [I Can't get internet access from the Ethernet port (Common)](https://github.com/iamromulan/quectel-rgmii-configuration-notes/tree/main?tab=readme-ov-file#i-cant-get-internet-access-from-the-ethernet-port-common)
 - If you don't get an error you should be getting replies back endlessly, press `CTRL-C` to stop it.
 - Simply Copy/Paste this into your Command Prompt/Shell 
```
adb root
adb shell
```
Then run
```
cd /tmp && wget -O rcPCIe_SDXPINN_toolkit.sh https://raw.githubusercontent.com/iamromulan/quectel-rgmii-toolkit/SDXPINN/rcPCIe_SDXPINN_toolkit.sh && chmod +x rcPCIe_SDXPINN_toolkit.sh && ./rcPCIe_SDXPINN_toolkit.sh && cd /
```


# Useful AT Commands 

You can send more than one command at once by sperating them with ``;`` and not including the AT part. ``AT+QENG="servingcell";+QCAINFO`` for example to see the info from both ``AT+QENG="servingcell"`` and ``AT+QCAINFO``


## PCIe RC Ethernet mode setup

For use with a board like the [Rework.Network PoE 2.5gig RJ45 sled](https://rework.network/collections/lte-home-gateway/products/5g2phy)

### For x70 modems (RM550/551)

For BETA versions of firmware: the adb value 2 trick still works so one and done:

``AT+QCFG="pcie/mode",1;+QCFG="usbnet",1;+QCFG="usbcfg",0x2C7C,0x0122,1,1,1,1,1,2,0;+CFUN=1,1``

OR if you are running the latest non-beta firmware 

``AT+QCFG="pcie/mode",1;+QCFG="usbnet",1``

Then unlock ADB:

Ask the modem for its adb code by sending: ``AT+QADBKEY?``

It'll respond with something like ``+QADBKEY: 29229988``

Take that number and paste it in this generator: https://onecompiler.com/python/3znepjcsq (hint: where it says STDIN)

You should get something like 

``AT+QADBKEY="mrX4zOPwdSIEjfM"``

Send that command to the modem and adb will be able to be turned on with the next command

Now you can turn it on with the usbcfg command ``AT+QCFG="usbcfg"``

***Be super careful, this controls what ports are on/off over USB.***

Run it and you will get the current settings. Something like this: 

``+QCFG: "usbcfg",0x2C7C,0x0122,1,1,1,1,1,0,0``

Send ``AT+QCFG="usbcfg",0x2C7C,0x0122,1,1,1,1,1,1,0`` to enable adb

Now you can reboot: ``AT+CFUN=1,1``



This will do the following:

- Enable PCIe RC mode (Driver selection is automatic now) 
- Set to ECM mode via USB and AP mode connection behavior
- Force Enables ADB Access 
- Reboots after all the above

Tip: APN automatic selection will somtimes choose the wrong APN. You may need to set your APN after powering up with the SIM inserted.

## The List
  - ``AT+CFUN=1,1`` (reboot)
  - ``AT+CFUN=0;CFUN=1`` (Disconnect then reconnect)(tip: run this after chnaging APN and you don't have to reboot)
  - ``AT+QMAPWAC? ``(get current status of auto connect, 0=disabled 1=enabled)
- ``AT+QMAPWAC=1`` (enable auto connect internet for ethernet)
- ``AT+QMAPWAC=0`` (disable auto connect for ethernet; use when you want internet over USB to work; IPPT must be disabled)
- ``AT+QUIMSLOT?`` (get active sim slot; 1=Slot 1; 2=Slot 2)
   - ``AT+QUIMSLOT=1`` (switch to sim slot 1)
   - ``AT+QUIMSLOT=2`` (switch to sim slot 2)           
 - ``AT+CGDCONT?`` (Get active APN profle st 1 through 8)
 - ``AT+QMBNCFG="AutoSel",0;+QMBNCFG="Deactivate"`` (Disable Automatic APN selection)(You will need to set your APN when you switch SIMs or Slots)(Can also set APN after you switch the run ``AT+CFUN=0;CFUN=1``
   - ``AT+CGDCONT=1,"IPV4V6","APNHERE"`` (Sets APN profile 1 to APNHERE using both IPV4 and IPV6)
  - ``AT+GSN`` (Show current IMEI)
  - ``AT+EGMR=0,7`` (Show current IMEI)
   - ``AT+EGMR=1,7,"IMEIGOESHERE"`` (sets/repairs IMEI)
   - ``AT+QCFG="usbcfg",0x2C7C,0x0801,1,1,1,1,1,2,0`` (enables adb bypasses adb key)
   - ``AT+QENG="servingcell"`` (shows anchor band and network connection status)
- ``AT+QCAINFO`` (Show all connected bands/CA info)
- ``AT+QNWPREFCFG="mode_pref"`` (Check what the current network search mode is set to)
- ``AT+QNWPREFCFG="mode_pref",AUTO`` (Set network search mode to automatic)
- ``AT+QNWPREFCFG="mode_pref",NR5G:LTE`` (Set network search mode to 5GNR and 4GLTE only)
- ``AT+QNWPREFCFG="mode_pref",NR5G`` (Set network search mode to 5GNR only)
- ``AT+QNWPREFCFG="mode_pref",LTE`` (Set network search mode to 4GLTE only)
- ``AT+QNWPREFCFG="nr5g_disable_mode"`` (Check to see if SA or NSA NR5G is disabled)
- ``AT+QNWPREFCFG="nr5g_disable_mode",0`` (Enable Both SA and NSA 5GNR)
- ``AT+QNWPREFCFG="nr5g_disable_mode",1`` (Disable SA 5GNR only)
- ``AT+QNWPREFCFG="nr5g_disable_mode",2`` (Disable NSA 5GNR only)
- ``AT+QNWPREFCFG="nr5g_band"`` (Get current SA 5GNR bandlock settings)
- ``AT+QNWPREFCFG="nsa_nr5g_band"`` (Get current NSA 5GNR bandlock settings)
- ``AT+QNWPREFCFG="nr5g_band",1:2:3:4:5:6`` (Example: Lock to SA 5G/NR bands n1,n2,n3,n4,n5, and n6)
- ``AT+QNWPREFCFG="nsa_nr5g_band",1:2:3:4:5:6`` (Example: Lock to SA 5G/NR bands n1,n2,n3,n4,n5, and n6)
- ``AT+QNWPREFCFG="lte_band"`` (Get current 4GLTE bandlock settings)
- ``AT+QNWPREFCFG="lte_band",1:2:3:4:5:6`` (Example: Lock to 4G/LTE bands 1,2,3,4,5, and 6)
- ``AT+QMAP="WWAN"`` (Show currently assigned IPv4 and IPv6 from the provider)
- ``AT+QMAP="LANIP"`` (Show current DHCP range and Gateway address for VLAN0)
- ``AT+QMAP="LANIP",IP_start_range,IP_end_range,Gateway_IP `` (Set IPv4 Start/End range and Gateway IP of DHCP for VLAN0)
- ``AT+QMAP="DHCPV4DNS","disable"`` (disable the onboard DNS proxy; recommended for IPPT)
- ``AT+QMAP="MPDN_rule",0,1,0,1,1,"FF:FF:FF:FF:FF:FF"``
(:warning: On the RM551E-GL you must specify the ethernet devices MAC address instead of FF:FF:FF...)
- ``AT+QMAP="MPDN_rule",0`` (turn off IPPT/clear MPDN rule 0; Remember to run AT+QMAPWAC=1 and reboot after)





## Acknowledgements
### GitHub Users/Individuals:
Thank You to: 

[Nate Carlson](https://github.com/natecarlson) for the Original Telnet Deamon/socat bridge usage and the Original RGMII Notes

[aesthernr](https://github.com/aesthernr)  for creating the Original Simple Admin

[rbflurry](https://github.com/rbflurry/) for inital Simple Admin fixes

[dr-dolomite](https://github.com/dr-dolomite) for simpleadmin 2.0 and QuecManager!

[tarunVreddy](https://github.com/tarunVreddy) for helping with the SA band aggregation parse

### Existing projects:

Tailscale was obtained through Tailscale's static build page. Since these modems have a 32-bit ARM processor on-board I used the arm package. https://pkgs.tailscale.com/stable/#static

TTYd was obtained from the [TTYd Project](https://github.com/tsl0922/ttyd)
