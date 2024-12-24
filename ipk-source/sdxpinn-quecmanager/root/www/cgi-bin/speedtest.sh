#!/bin/sh

SPEEDTEST_OUTPUT=$(speedtest)

SERVER=$(echo "$SPEEDTEST_OUTPUT" | grep -o -E 'Server: [^(]' | cut -d':' -f2 | tr -d ' ')
SERVER_ID=$(echo "$SPEEDTEST_OUTPUT" | grep -o -E 'id: [0-9]' | cut -d':' -f2 | tr -d ' ')
ISP=$(echo "$SPEEDTEST_OUTPUT" | grep -o -E 'ISP: [^(]' | cut -d':' -f2 | tr -d ' ')
IDLE_LATENCY=$(echo "$SPEEDTEST_OUTPUT" | grep -o -E 'Idle Latency: [0-9.] ms' | cut -d':' -f2 | tr -d ' ms')
DOWNLOAD_LATENCY=$(echo "$SPEEDTEST_OUTPUT" | grep -o -E 'Download: [0-9.]* ms' | cut -d':' -f2 | tr -d ' ms')
DOWNLOAD_SPEED=$(echo "$SPEEDTEST_OUTPUT" | grep -o -E 'Download: [0-9.]* Mbps' | cut -d':' -f2 | tr -d ' Mbps')
DOWNLOAD_DATA_USED=$(echo "$SPEEDTEST_OUTPUT" | grep -o -E 'data used: [0-9.]* MB' | cut -d':' -f2 | tr -d ' MB')
UPLOAD_LATENCY=$(echo "$SPEEDTEST_OUTPUT" | grep -o -E 'Upload: [0-9.]* ms' | cut -d':' -f2 | tr -d ' ms')
UPLOAD_SPEED=$(echo "$SPEEDTEST_OUTPUT" | grep -o -E 'Upload: [0-9.]* Mbps' | cut -d':' -f2 | tr -d ' Mbps')
UPLOAD_DATA_USED=$(echo "$SPEEDTEST_OUTPUT" | grep -o -E 'data used: [0-9.]* MB' | cut -d':' -f2 | tr -d ' MB')
RESULT_URL=$(echo "$SPEEDTEST_OUTPUT" | grep -o -E 'Result URL: [^.]*' | cut -d':' -f2 | tr -d ' ')

echo "Content-Type: application/json"
echo ""
echo "{
"server": "$SERVER",
"serverId": "$SERVER_ID",
"isp": "$ISP",
"idleLatency": $IDLE_LATENCY,
"downloadLatency": $DOWNLOAD_LATENCY,
"downloadSpeed": $DOWNLOAD_SPEED,
"downloadDataUsed": $DOWNLOAD_DATA_USED,
"uploadLatency": $UPLOAD_LATENCY,
"uploadSpeed": $UPLOAD_SPEED,
"uploadDataUsed": $UPLOAD_DATA_USED,
"resultUrl": "$RESULT_URL"
}"
