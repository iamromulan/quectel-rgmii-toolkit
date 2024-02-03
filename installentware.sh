#!/bin/sh

#TYPE='generic'
TYPE='alternative'

#|---------|-----------------------|---------------|---------------|---------------------|-------------------|-------------------|----------------------|-------------------|
#| ARCH    | aarch64-k3.10         | armv5sf-k3.2  | armv7sf-k2.6  | armv7sf-k3.2        | mipselsf-k3.4     | mipssf-k3.4       | x64-k3.2             | x86-k2.6          |
#| LOADER  | ld-linux-aarch64.so.1 | ld-linux.so.3 | ld-linux.so.3 | ld-linux.so.3       | ld.so.1           | ld.so.1           | ld-linux-x86-64.so.2 | ld-linux.so.2     |
#| GLIBC   | 2.27                  | 2.27          | 2.23          | 2.27                | 2.27              | 2.27              | 2.27                 | 2.23              |
#|---------|-----------------------|---------------|---------------|---------------------|-------------------|-------------------|----------------------|-------------------|

unset LD_LIBRARY_PATH
unset LD_PRELOAD

ARCH=armv7sf-k3.2
LOADER=ld-linux.so.3
GLIBC=2.27

echo 'Info: Checking for prerequisites and creating folders...'
if [ -d /usrdata/opt ]; then
    echo 'Warning: Folder /usrdata/opt exists!'
else
    mkdir /usrdata/opt
fi
# no need to create many folders. entware-opt package creates most
for folder in bin etc lib/opkg tmp var/lock
do
  if [ -d "/usrdata/opt/$folder" ]; then
    echo "Warning: Folder /usrdata/opt/$folder exists!"
    echo 'Warning: If something goes wrong please clean /usrdata/opt folder and try again.'
  else
    mkdir -p /usrdata/opt/$folder
  fi
done

echo 'Info: Opkg package manager deployment...'
URL=http://bin.entware.net/${ARCH}/installer
wget $URL/opkg -O /usrdata/opt/bin/opkg
chmod 755 /usrdata/opt/bin/opkg
wget $URL/opkg.conf -O /usrdata/opt/etc/opkg.conf

echo 'Info: Basic packages installation...'
/usrdata/opt/bin/opkg update
if [ $TYPE = 'alternative' ]; then
  /usrdata/opt/bin/opkg install busybox
fi
/usrdata/opt/bin/opkg install entware-opt

# Fix for multiuser environment
chmod 777 /usrdata/opt/tmp

for file in passwd group shells shadow gshadow; do
  if [ $TYPE = 'generic' ]; then
    if [ -f /etc/$file ]; then
      ln -sf /etc/$file /usrdata/opt/etc/$file
    else
      [ -f /usrdata/opt/etc/$file.1 ] && cp /usrdata/opt/etc/$file.1 /usrdata/opt/etc/$file
    fi
  else
    if [ -f /usrdata/opt/etc/$file.1 ]; then
      cp /usrdata/opt/etc/$file.1 /usrdata/opt/etc/$file
    fi
  fi
done

[ -f /etc/localtime ] && ln -sf /etc/localtime /usrdata/opt/etc/localtime

echo 'Info: Congratulations!'
echo 'Info: If there are no errors above then Entware was successfully initialized.'
echo 'Info: Add /usrdata/opt/bin & /usrdata/opt/sbin to $PATH variable'
echo 'Info: Add "/usrdata/opt/etc/init.d/rc.unslung start" to startup script for Entware services to start'
if [ $TYPE = 'alternative' ]; then
  echo 'Info: Use ssh server from Entware for better compatibility.'
fi
echo 'Info: Found a Bug? Please report at https://github.com/Entware/Entware/issues'
