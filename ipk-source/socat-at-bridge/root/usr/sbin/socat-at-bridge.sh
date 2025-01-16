#!/bin/ash

# Optional logging for debugging
LOGFILE="/var/log/socat-bridge.log"

# Start socat to create virtual TTY devices
echo "$(date): Starting socat..." >> "$LOGFILE"
socat -d -d pty,link=/dev/ttySMD11IN,raw,echo=0,group=20,perm=660 \
          pty,link=/dev/ttySMD11,raw,echo=1,group=20,perm=660 &
SOCAT_PID=$!

# Allow socat to initialize
sleep 1

# Start forwarding data from /dev/smd11 to /dev/ttySMD11IN
echo "$(date): Starting forward from /dev/smd11 to /dev/ttySMD11IN..." >> "$LOGFILE"
cat /dev/smd11 > /dev/ttySMD11IN &
CAT1_PID=$!

# Start forwarding data from /dev/ttySMD11IN to /dev/smd11
echo "$(date): Starting forward from /dev/ttySMD11IN to /dev/smd11..." >> "$LOGFILE"
cat /dev/ttySMD11IN > /dev/smd11 &
CAT2_PID=$!

# Handle script termination and cleanup
cleanup() {
    echo "$(date): Cleaning up processes..." >> "$LOGFILE"
    kill "$SOCAT_PID" "$CAT1_PID" "$CAT2_PID" 2>/dev/null
    wait
    echo "$(date): All processes stopped." >> "$LOGFILE"
}

# Trap termination signals to run cleanup
trap cleanup INT TERM EXIT

# Wait for all background processes to finish
wait
