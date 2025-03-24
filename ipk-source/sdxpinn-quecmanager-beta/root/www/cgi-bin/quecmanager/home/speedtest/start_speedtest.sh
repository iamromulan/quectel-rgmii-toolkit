#!/bin/sh
# Location: /www/cgi-bin/quecmanager/home/speedtest/start_speedtest.sh

STATUS_FILE="/tmp/speedtest_status.json"
FINAL_RESULT="/tmp/speedtest_final.json"

# Set content type header
echo "Content-Type: application/json"
echo ""

# Remove any existing status files
rm -f $STATUS_FILE
rm -f $FINAL_RESULT

# Initialize status file
echo '{"status": "starting"}' > $STATUS_FILE
chmod 644 $STATUS_FILE

# Run speedtest in background and pipe output to status file
(
    export HOME=/tmp/home
    /usr/bin/speedtest --accept-license -f json -p yes --progress-update-interval=100 | \
    while IFS= read -r line; do
        # Update status file with latest JSON data
        echo "$line" > $STATUS_FILE
        
        # If this is a result line, also save it as the final result
        if echo "$line" | grep -q '"type":"result"'; then
            echo "$line" > $FINAL_RESULT
            chmod 644 $FINAL_RESULT
        fi
    done
) &

# Return immediate success response
echo '{"status":"started"}'