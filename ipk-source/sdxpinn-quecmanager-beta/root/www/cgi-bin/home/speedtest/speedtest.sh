#!/bin/sh
export HOME=/tmp/home

# Create named pipe for speedtest output if it doesn't exist
[ ! -p /tmp/realtime_spd.json ] && mkfifo /tmp/realtime_spd.json

# Run speedtest in background
/usr/bin/speedtest --accept-license -f json -p yes --progress-update-interval=100 > /tmp/realtime_spd.json

# Remove named pipe
rm /tmp/realtime_spd.json