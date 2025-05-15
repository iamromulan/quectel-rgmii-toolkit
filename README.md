# Quectel Application Processor Repository (repo to be renamed soon)
Current Branch: **Main**

# About
- Software deployment Toolkits and opkg repositories intended to deploy directly to the Application Processor (AP) (Linux OS running the modem) of a Quectel Cellular Modem.
	- Basic goal for each branch/platform: A deployment script that sets up a usable mount space and deploys an opkg setup + an opkg feed for said platform. 
- Target use scenario: RC PCIe Mode where the modem utilizes an ethernet chipset EP directly. (Example hardware: [Rework.Network PHY Adapter](https://www.rework.network/collections/lte-home-gateway/products/5g2phy))
- Should be possible to benefit from this repo as well if you use the modem in other scenarios as well. Through tailscale you can acess the AP's LAN and other services installable from this repo.

# Branches

## Main/Stable:

- [SDXLEMUR and SDXPRAIRIE platforms (QTI Linux system armv7 32-bit)](https://github.com/iamromulan/quectel-rgmii-toolkit/tree/SDXLEMUR) 
	- Confirmed working / For use with the following modems:

		- RM500Q-GL (No page yet, i don't own one)

   		- [RM502Q-AE](https://github.com/iamromulan/cellular-modem-wiki/blob/main/quectel/sdxprairie/RM502Q-AE.md)

	 	- [RM520N-GL](https://github.com/iamromulan/cellular-modem-wiki/blob/main/quectel/sdxlemur/RM520N-GL.md)

   		- [RM521F-GL](https://github.com/iamromulan/cellular-modem-wiki/blob/main/quectel/sdxlemur/RM521F-GL.md)

   	- Will probably work fine on:

		- RM530N-GL

    		- Other Quectel SDXLEMUR/SDXPRAIRIE modems with a QTI Linux system and armv7 32-bit processor

- [SDXPINN platform OpenWRT system armv8-A 64-bit](https://github.com/iamromulan/quectel-rgmii-toolkit/tree/SDXPINN)
	- Confirmed working / For use with the following modems:

   		- [RM550V-GL](https://github.com/iamromulan/cellular-modem-wiki/blob/main/quectel/sdxpinn/RM550V-GL.md) :warning: You need iamromulan's RM550V-GL firmware for PCIe RC mode to work :warning:

	 	- [RM550V-GL](https://github.com/iamromulan/cellular-modem-wiki/blob/main/quectel/sdxpinn/RM551E-GL.md)

   	- Will probably work fine on:
		
  		- Other Quectel SDXPINN modems with a OpenWRT system and armv8-A 64-bit processor


## Development/Testing/Unstable

> :bulb: Open pull requests pointed to these branches. 

These branches are meant for testing new changes and edits. Do not deploy or install packages from these branches unless you are ready to handle any issues that occur. In general these branches are for testing recent PRs and commits.

- [SDXLEMUR and SDXPRAIRIE platforms (QTI Linux system armv7 32-bit)](https://github.com/iamromulan/quectel-rgmii-toolkit/tree/development-SDXLEMUR)

- [SDXPINN platform OpenWRT system armv8-A 64-bit](https://github.com/iamromulan/quectel-rgmii-toolkit/tree/development-SDXPINN)

## Temporary/Experimental/Overhaul branches

These branches are for large overhauls or experimentation that needs to happen on their own branch. These are usualy temporary branches and are deleted when no longer needed.

- [OVERHAUL: SDXLEMUR and SDXPRAIRIE platforms (QTI Linux system armv7 32-bit)](https://github.com/iamromulan/quectel-rgmii-toolkit/tree/overhaul-SDXLEMUR)

	- This branch is being used to create a similar model to how SDXPINN branches behave. A new mount-fix is needed along with a solid plan for how to approch the opkg rework. Indexing already installed "packages" is recomeneded in order to avoid duplicate installs/save space. The goal will be to package all applications as IPKs and hopefuly port QuecManager and Luci over to it. 


