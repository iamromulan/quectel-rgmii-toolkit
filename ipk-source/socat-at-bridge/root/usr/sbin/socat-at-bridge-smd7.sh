#!/bin/ash

# Optional logging for debugging
LOGFILE="/var/log/socat-bridge-smd7.log"

# Start socat to create virtual TTY devices
echo "$(date): Starting socat..." >> "$LOGFILE"
socat -d -d pty,link=/dev/ttySMD7IN,raw,echo=0,group=20,perm=660 \
          pty,link=/dev/ttySMD7,raw,echo=1,group=20,perm=660 &
SOCAT_PID=$!

# Allow socat to initialize
sleep 1

# Start forwarding data from /dev/smd7 to /dev/ttySMD7IN
echo "$(date): Starting forward from /dev/smd7 to /dev/ttySMD7IN..." >> "$LOGFILE"
cat /dev/smd7 > /dev/ttySMD7IN &
CAT1_PID=$!

# Start forwarding data from /dev/ttySMD7IN to /dev/smd7
echo "$(date): Starting forward from /dev/ttySMD7IN to /dev/smd7..." >> "$LOGFILE"
cat /dev/ttySMD7IN > /dev/smd7 &
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
