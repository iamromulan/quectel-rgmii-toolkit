#!/bin/sh
# Location: /www/cgi-bin/quecmanager/home/speedtest/speedtest_status.sh

STATUS_FILE="/tmp/speedtest_status.json"
FINAL_RESULT="/tmp/speedtest_final.json"

echo "Content-Type: application/json"
echo "Cache-Control: no-cache, no-store, must-revalidate"
echo "Pragma: no-cache"
echo "Expires: 0"
echo ""

# Check if the test is completed and we have a final result
if [ -f "$FINAL_RESULT" ] && [ -r "$FINAL_RESULT" ] && [ -s "$FINAL_RESULT" ]; then
    # Return the saved final result
    cat $FINAL_RESULT
elif [ -f "$STATUS_FILE" ]; then
    # Check if the file is readable and not empty
    if [ -r "$STATUS_FILE" ] && [ -s "$STATUS_FILE" ]; then
        # Return current status if test is running
        cat $STATUS_FILE
    else
        # File exists but is empty or not readable
        echo '{"status": "pending", "message": "Test initializing..."}'
    fi
else
    # Indicate no active test
    echo '{"status": "not_running"}'
fi