#!/usrdata/micropython/micropython

# Add the /usrdata/micropython directory to sys.path so we can find the external modules.
# TODO: Move external modules to lib?
# TODO: Recompile Micropython with a syspath set up for our use case.
import sys
# Remove the home directory from sys.path.
if "~/.micropython/lib" in sys.path:
    sys.path.remove("~/.micropython/lib")
sys.path.append("/usrdata/micropython")

import serial
import uos


atcmd = sys.argv[1]

ser = serial.Serial("/dev/ttyOUT", baudrate=115200)
ser.write(atcmd + "\r\n")

uos.system("sleep 0.025s")
# wait for an OK
out=r''
while ser.in_waiting > 0:
    out += ser.read(1)

if "OK" not in str(out):
    print('Error NOT OK')

print(out.decode('utf-8'))
ser.close()