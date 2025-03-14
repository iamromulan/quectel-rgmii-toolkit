#!/bin/sh
# /www/cgi-bin/start_speedtest.sh
echo "Content-Type: application/json"
echo ""

# Run speedtest in background
/www/cgi-bin/quecmanager/home/speedtest/speedtest.sh

# Immediately return a success response
echo '{"status":"started"}'