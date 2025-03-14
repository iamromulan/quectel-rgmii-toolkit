#!/bin/sh

echo "Content-Type: text/event-stream"
echo "Cache-Control: no-cache"
echo "Connection: keep-alive"
echo ""

# Use cat to read from the FIFO
cat /tmp/realtime_spd.json | while read line; do
    echo "data: $line"
    echo
    sleep 0.1
done