# AT Telnet Daemon for Quectel Modem

This will provide a telnet interface to the AT command port of Quectel modems that are connected via a RGMII Ethernet interface (aka a "RJ45 to M.2" or "Ethernet to M.2" adapter board). It is an alternative to the ETH AT command interface that Quectel provides, which is a bit flaky and requires a custom client.

The downside is this does require ADB. But that documentation is covered on my main page: [https://github.com/natecarlson/quectel-rgmii-configuration-notes](https://github.com/natecarlson/quectel-rgmii-configuration-notes)

If you're interested in supporting more work on things like this:

<a href="https://www.buymeacoffee.com/natecarlson" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/default-orange.png" alt="Buy Me A Coffee" height="41" width="174"></a> <!-- markdownlint-disable-line -->

## Features

* Supports multiple clients connected via telnet at the same time. They will all see the same data. Commands entered by the clients are send in the order they are received; there _shouldn't_ be any problems with commands getting garbled by multiple inputs. (The intent of this is to allow other scripts to connect via TCP and inject commands into the modem.. for example, a connection stats monitoring script.)
* Relatively lightweight; uses the Unix port of Micropython, which is remarkably small. Having Micropython available on the modem also opens up many other opportunities; however, be aware that it isn't at parity with CPython, and that it needs different modules (ie, you can't just use pip.)

![at-command-daemon-client-example](https://github.com/natecarlson/quectel-rgmii-at-command-client/assets/502200/b5133c55-07c3-41b6-adc6-69ae4eca2052)

## Known issues

* **This currently only works with RM520 modems!** My build environment targeted the library versions of the RM520; the other modems have an older environment. I'll rebuild on an older base version soonish.
* If your telnet client sends each character individually (instead of waiting for you to press enter), this won't work properly. I'll get a patch in for it soonish. I've confirmed that with default settings putty, netcat, and NetKit telnet all work fine. (I'll always recommend using a client that waits to send until you hit enter, though, as it makes it possible to fix type-o's before sending to the modem!)
* ~~This currently listens on port 5000 on all interfaces. If you're not behind CGNAT, this is a big risk!~~ It now listens on both IPv4 and IPv6, but sets up a firewall rule to prevent external access. If your public input interface is something under than rmnet+, it will not work, however.
* It's also currently unauthenticated.
* The connection is not encrypted.
* The socat binary is from a different source. I will add a public build for it at some point, which will alleviate risk. For now, I haven't seen anything suspicious about it.
* The method I use to interact with the smd11 interface is kind of a kludge right now. Micropython doesn't have direct os.open support, and I haven't been able to figure out a way to interact directly with /dev/smd11 from python without that, due to missing ioctls/etc. So, I've set up a socat instance that listens on /dev/ttyIN and /dev/ttyOUT. I then use a pair of cat's - one reading from smd11 and writing to ttyIN, and one reading from ttyIN and writing to smd11. It's all automated by the systemd scripts, including proper restarts/etc, but it's still a bit of a kludge. I'm open to suggestions on how to improve this.
* I haven't tested this with modems other than the RM520 as of yet.
* I'm not super happy with the micropython build I'm shipping right now - but it does work! I plan on modifying it to clean up the sys.path to make it easier to install additional extensions/etc.

## Requirements

* **RM520** modem. It will not work on RM50x yet (see above.)
* ADB access to the modem

## Installation

* Clone this repository to a host connected via USB to the modem
* In a shell, navigate to the at_telnet_daemon directory.
* Run the following commands from your host:

```bash
adb push micropython /usrdata/micropython
adb push at-telnet /usrdata/at-telnet
adb shell chmod +x /usrdata/micropython/micropython /usrdata/at-telnet/modem-multiclient.py /usrdata/at-telnet/socat-armel-static /usrdata/at-telnet/picocom
adb shell mount -o remount,rw /
adb shell cp /usrdata/at-telnet/systemd_units/*.service /lib/systemd/system
adb shell systemctl daemon-reload
adb shell ln -s /lib/systemd/system/at-telnet-daemon.service /lib/systemd/system/multi-user.target.wants/
adb shell ln -s /lib/systemd/system/socat-smd11.service /lib/systemd/system/multi-user.target.wants/
adb shell ln -s /lib/systemd/system/socat-smd11-to-ttyIN.service /lib/systemd/system/multi-user.target.wants/
adb shell ln -s /lib/systemd/system/socat-smd11-from-ttyIN.service /lib/systemd/system/multi-user.target.wants/
adb shell mount -o remount,ro /
adb shell systemctl start socat-smd11
adb shell sleep 2s
adb shell systemctl start socat-smd11-to-ttyIN
adb shell systemctl start socat-smd11-from-ttyIN
adb shell systemctl start at-telnet-daemon
```

Now, it should be ready for you to connect on port 5000.

## Troubleshooting

### I can type commands in, but I don't see any output

I haven't perfected the systemd units yet. If it doesn't work, sometimes it might help to stop everything and start it again, one by one..

```bash
adb shell systemctl stop at-telnet-daemon socat-smd11 socat-smd11-to-ttyIN socat-smd11-from-ttyIN
adb shell systemctl start socat-smd11
adb shell sleep 2s
adb shell systemctl start socat-smd11-to-ttyIN
adb shell systemctl start socat-smd11-from-ttyIN
adb shell systemctl start at-telnet-daemon
```

If it still doesn't work, log in and try picocom:

```bash
adb shell
systemctl stop at-telnet-daemon
/usrdata/at-telnet/picocom /dev/ttyOUT
```

..and see if you can issue AT commands. (Ctrl-A, Ctrl-X to exit picocom - hold down Ctrl the whole time.)

If it works there, try manually launching the daemon from your adb shell: `/usrdata/at-telnet/modem-multiclient.py`. The first thing it does is issues an ATE0 command, so if the bridge isn't working, you will get:

```bash
bash-3.2# ./modem-multiclient.py
[2023-07-08 16:21:33: INFO/606ms] AT Server listening on TCP port 5000
[2023-07-08 16:21:33: WARNING/638ms] Did not get expected OK when running ATE0. Result: b''
```

If it's still not working, let me know!
