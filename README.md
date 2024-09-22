# RGMII Toolkit
Software deployment Toolkit for Quectel RM5xxx series 5G modems utilizing an m.2 to RJ45 adapter (RGMII)

Current Branch: **SDXPINN**

This is a work in progress branch for early development for the RM551E-GL modem (Will probably work on the 550 as well)

# Devleopment Branch: the below commands will download the beta/work in progress toolkit only for RM55x modems/SDXPINN platform

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

## Acknowledgements
### GitHub Users/Individuals:
Thank You to: 

[Nate Carlson](https://github.com/natecarlson) for the Original Telnet Deamon/socat bridge usage and the Original RGMII Notes

[aesthernr](https://github.com/aesthernr)  for creating the Original Simple Admin

[rbflurry](https://github.com/rbflurry/) for inital Simple Admin fixes

[dr-dolomite](https://github.com/dr-dolomite) for some major stat page improvements and this repos first approved external PR!

[tarunVreddy](https://github.com/tarunVreddy) for helping with the SA band aggregation parse

### Existing projects:
Simpleadmin heavily uses the AT Command Parsing Scripts (Basically a copy with new changes and tweaks) of Dairyman's Rooter Source https://github.com/ofmodemsandmen/ROOterSource2203

Tailscale was obtained through Tailscale's static build page. Since these modems have a 32-bit ARM processor on-board I used the arm package. https://pkgs.tailscale.com/stable/#static

Entware/opkg was obtained through [Entware's wiki](https://github.com/Entware/Entware/wiki/Alternative-install-vs-standard) and the installer heavily modified by [iamromulan](https://github.com/iamromulan) for use with Quectel modems

TTYd was obtained from the [TTYd Project](https://github.com/tsl0922/ttyd)
