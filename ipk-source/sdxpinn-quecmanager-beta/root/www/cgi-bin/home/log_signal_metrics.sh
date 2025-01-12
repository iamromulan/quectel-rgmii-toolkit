#!/bin/sh

# Configuration
LOGDIR="/www/signal_graphs"
MAX_ENTRIES=10
INTERVAL=15
QSCAN_FILE="$LOGDIR/qscan.json"
LOCK_FILE="/tmp/signal_logging.lock"
PAUSE_FILE="/tmp/signal_logging.pause"

# Ensure the directory exists
mkdir -p "$LOGDIR"

# Modified clean_atinout_output function - less aggressive cleaning
clean_atinout_output() {
    # Keep everything between the command and OK, including the actual response
    sed '1d' | sed '/^OK$/d' | tr -d '\r' | grep -v '^$' | head -n1
}

# Function to perform cell scan and output JSON response for CGI
perform_cell_scan() {
    # Print CGI headers first
    printf "Content-Type: application/json\n\n"
    
    # Create pause file to stop continuous logging
    touch "$PAUSE_FILE"
    
    # Wait for any ongoing logging to complete
    sleep 2
    
    # Perform cell scan sequence
    echo "AT+COPS=2" | atinout - /dev/smd7 -
    sleep 2
    
    # Run QSCAN and save output to temporary file
    echo "AT+QSCAN=3,1" | atinout - /dev/smd7 "$QSCAN_OUT"
    sleep 2
    
    # Process QSCAN output and convert to JSON
    if [ -f "$QSCAN_OUT" ]; then
        # Extract the relevant part and convert to JSON format
        sed -n '2,/^OK$/p' < "$QSCAN_OUT" | sed '$d' | tr -d '\r' | \
        jq -R -s 'split("\n") | map(select(length > 0))' > "$QSCAN_FILE"
    fi
    
    # Re-enable network registration
    echo "AT+COPS=0" | atinout - /dev/smd7 -
    sleep 2
    
    # Clean up temporary file
    rm -f "$QSCAN_OUT"
    
    # Remove pause file to resume logging
    rm -f "$PAUSE_FILE"
    
    # Return QSCAN results as JSON
    if [ -f "$QSCAN_FILE" ]; then
        printf '{"status":"success","data":%s}\n' "$(cat "$QSCAN_FILE")"
    else
        printf '{"status":"error","message":"No scan results available"}\n'
    fi
}


# Function to log signal metric
log_signal_metric() {
    [ -f "$PAUSE_FILE" ] && return
    
    local COMMAND="$1"
    local FILENAME="$2"
    local LOGFILE="$LOGDIR/$FILENAME"
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$LOGFILE")"
    
    # Get current timestamp
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Add debug logging
    logger -t signal_metrics "Running command: $COMMAND"
    
    # Run the AT command and capture its output, then clean it
    SIGNAL_OUTPUT=$(echo "$COMMAND" | atinout - /dev/smd7 - | clean_atinout_output)
    
    # Log the raw output for debugging
    logger -t signal_metrics "Raw output for $COMMAND: $SIGNAL_OUTPUT"
    
    # Ensure the file exists and is a valid JSON array
    [ ! -s "$LOGFILE" ] && echo "[]" > "$LOGFILE"
    
    # Use jq to update the JSON file
    jq --arg dt "$TIMESTAMP" \
       --arg out "$SIGNAL_OUTPUT" \
       '. + [{"datetime": $dt, "output": $out}] | .[-'"$MAX_ENTRIES"':]' \
       "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
}

# Function to log data usage
log_data_usage() {
    [ -f "$PAUSE_FILE" ] && return
    
    local LOGFILE="$LOGDIR/data_usage.json"
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$LOGFILE")"
    
    # Get current timestamp
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Run the AT command and capture its output
    DATA_OUTPUT=$(echo "AT+QGDCNT?;+QGDNRCNT?" | atinout - /dev/smd7 - | clean_atinout_output)
    
    # Ensure the file exists and is a valid JSON array
    [ ! -s "$LOGFILE" ] && echo "[]" > "$LOGFILE"
    
    # Use jq to update the JSON file
    jq --arg dt "$TIMESTAMP" \
       --arg out "$DATA_OUTPUT" \
       '. + [{"datetime": $dt, "output": $out}] | .[-'"$MAX_ENTRIES"':]' \
       "$LOGFILE" > "${LOGFILE}.tmp" && mv "${LOGFILE}.tmp" "$LOGFILE"
}

# Main CGI request handler
handle_cgi_request() {
    # Get query string from REQUEST_URI or QUERY_STRING
    local QUERY=""
    if [ -n "$REQUEST_URI" ]; then
        QUERY=$(echo "$REQUEST_URI" | grep -o '[?&]request=[^&]*' | cut -d= -f2)
    elif [ -n "$QUERY_STRING" ]; then
        QUERY=$(echo "$QUERY_STRING" | grep -o 'request=[^&]*' | cut -d= -f2)
    fi

    case "$QUERY" in
        "cellScan")
            perform_cell_scan
            ;;
        *)
            printf "Content-Type: application/json\n\n"
            printf '{"status":"error","message":"Invalid request"}\n'
            ;;
    esac
}

# Function to start continuous logging
start_continuous_logging() {
    # Check if another instance is running
    if [ -f "$LOCK_FILE" ]; then
        logger -t signal_metrics "Another instance is already running"
        exit 1
    fi

    # Create lock file
    touch "$LOCK_FILE"

    # Cleanup on exit
    trap 'rm -f "$LOCK_FILE" "$PAUSE_FILE"; exit 0' INT TERM

    # Log start to system log
    logger -t signal_metrics "Starting continuous signal metrics logging"

    # Continuous logging loop
    while true; do
        if [ ! -f "$PAUSE_FILE" ]; then
            log_signal_metric "AT+QRSRP" "rsrp.json"
            log_signal_metric "AT+QRSRQ" "rsrq.json"
            log_signal_metric "AT+QSINR" "sinr.json"
            log_data_usage
        fi
        sleep "$INTERVAL"
    done
}

# Check if script is being run as CGI or directly
if [ -n "$REQUEST_URI" ] || [ -n "$QUERY_STRING" ]; then
    handle_cgi_request
else
    start_continuous_logging
fi