#!/bin/sh
# Ensure the directory exists
LOGDIR="/tmp/signal_graphs"
mkdir -p "$LOGDIR"
# Maximum number of entries
MAX_ENTRIES=10
# Interval between logs (in seconds)
INTERVAL=25
# Function to clean and extract actual output from atinout
clean_atinout_output() {
    # Remove first line (echoed command), last line (OK), and trim whitespace
    sed -n '2,/^OK$/p' | sed '$d' | tr -d '\r' | xargs
}
# Function to log signal metrics
log_signal_metric() {
    local COMMAND="$1"
    local FILENAME="$2"
    local LOGFILE="$LOGDIR/$FILENAME"
   
    # Ensure log directory exists
    mkdir -p "$(dirname "$LOGFILE")"
   
    # Get current timestamp
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
   
    # Run the AT command and capture its output, then clean it
    SIGNAL_OUTPUT=$(echo "$COMMAND" | atinout - /dev/smd11 - | clean_atinout_output)
   
    # Ensure the file exists and is a valid JSON array
    if [ ! -s "$LOGFILE" ]; then
        echo "[]" > "$LOGFILE"
    fi
   
    # Prepare new JSON entry
    ESCAPED_TIMESTAMP=$(printf '%s' "$TIMESTAMP" | sed 's/"/\\"/g')
    ESCAPED_OUTPUT=$(printf '%s' "$SIGNAL_OUTPUT" | sed 's/"/\\"/g')
   
    # Use jq with a more robust approach
    jq --arg datetime "$ESCAPED_TIMESTAMP" \
       --arg output "$ESCAPED_OUTPUT" \
       '
       # Ensure the input is always an array
       if type == "array" then . 
       else [] 
       end |
       # Add new entry
       . + [{"datetime": $datetime, "output": $output}] | 
       # Trim to max entries
       .[-'"$MAX_ENTRIES"':]
       ' "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
}
# Trap to handle script termination gracefully
cleanup() {
    echo "Stopping signal logging..."
    exit 0
}
trap cleanup SIGINT SIGTERM
# Continuous logging loop
echo "Starting continuous signal metrics logging (Press Ctrl+C to stop)..."
while true; do
    # Log RSRP
    log_signal_metric "AT+QRSRP" "rsrp.json"
    # Log RSRQ
    log_signal_metric "AT+QRSRQ" "rsrq.json"
    # Log SINR
    log_signal_metric "AT+QSINR" "sinr.json"
    # Wait for the specified interval
    sleep "$INTERVAL"
done