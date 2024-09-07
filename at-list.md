# Useful AT Commands 

You can send more than one command at once by sperating them with ``;`` and not including the AT part. ``AT+QENG="servingcell";+QCAINFO`` for example to see the info from both ``AT+QENG="servingcell"`` and ``AT+QCAINFO``


## PCIe RC Ethernet mode setup

### For RM500-RM521 modems
``AT+QETH="eth_driver","r8125",1;+QCFG="pcie/mode",1;+QCFG="usbnet",1;+QMAP="MPDN_rule",0,1,0,1,1,"FF:FF:FF:FF:FF:FF";+QMAP="DHCPV4DNS","disable";+QCFG="usbcfg",0x2C7C,0x0801,1,1,1,1,1,2,0;+CFUN=1,1``

This will do the following:

- Set the 2.5Gig Ethernet driver as active
- Enable PCIe RC mode
- Set to ECM mode via USB and AP mode connection behavior
- Enable IPPT
- Enable DNS IPPT (disables onboard proxy)
- Force Enables ADB Access 
- Reboots after all the above

### For x70 modems (RM550/551)
``AT+QCFG="pcie/mode",1;+QCFG="usbnet",1;+QCFG="usbcfg",0x2C7C,0x0801,1,1,1,1,1,2,0;+CFUN=1,1``

This will do the following:

- Enable PCIe RC mode (Driver selection is automatic now) 
- Set to ECM mode via USB and AP mode connection behavior
- Force Enables ADB Access 
- Reboots after all the above

## The List
  - ``AT+CFUN=1,1`` (reboot)
  - ``AT+QMAPWAC? ``(get current status of auto connect, 0=disabled 1=enabled)
- ``AT+QMAPWAC=1`` (enable auto connect internet for ethernet)
- ``AT+QMAPWAC=0`` (disable auto connect for ethernet; use when you want internet over USB to work; IPPT must be disabled)
- ``AT+QUIMSLOT?`` (get active sim slot; 1=Slot 1; 2=Slot 2)
   - ``AT+QUIMSLOT=1`` (switch to sim slot 1)
   - ``AT+QUIMSLOT=2`` (switch to sim slot 2)           
 - ``AT+CGDCONT?`` (Get active APN profle st 1 through 8)
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
- ``AT+QNWPREFCFG="nr5g_band"`` (Get current 5GNR bandlock
                    settings)
- ``AT+QNWPREFCFG="nr5g_band",1:2:3:4:5:6`` (Example: Lock to SA 5G/NR bands n1,n2,n3,n4,n5, and n6)
- ``AT+QNWPREFCFG="lte_band"`` (Get current 4GLTE bandlock settings)
- ``AT+QNWPREFCFG="lte_band",1:2:3:4:5:6`` (Example: Lock to 4G/LTE bands 1,2,3,4,5, and 6)
- ``AT+QMAP="WWAN"`` (Show currently assigned IPv4 and IPv6 from the provider)
- ``AT+QMAP="LANIP"`` (Show current DHCP range and Gateway address for VLAN0)
- ``AT+QMAP="LANIP",IP_start_range,IP_end_range,Gateway_IP `` (Set IPv4 Start/End range and Gateway IP of DHCP for VLAN0)
- ``AT+QMAP="DHCPV4DNS","disable"`` (disable the onboard DNS proxy; recommended for IPPT)
- ``AT+QMAP="MPDN_rule",0,1,0,1,1,"FF:FF:FF:FF:FF:FF"`` (Turn on IP Passthrough for Ethernet)
(:warning: On the RM551E-GL you must specify the ethernet devices MAC address instead of FF:FF:FF...)
- ``AT+QMAP="MPDN_rule",0`` (turn off IPPT/clear MPDN rule 0; Remember to run AT+QMAPWAC=1 and reboot after)