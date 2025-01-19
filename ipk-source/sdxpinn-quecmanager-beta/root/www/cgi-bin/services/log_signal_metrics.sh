#!/bin/sh

# Configuration
LOGDIR="/www/signal_graphs"
MAX_ENTRIES=10
INTERVAL=60
QUEUE_FILE="/tmp/at_pipe.txt"
FETCH_LOCK_KEYWORD="FETCH_LOCK"
PAUSE_FILE="/tmp/signal_logging.pause"

# Ensure the directory exists
mkdir -p "$LOGDIR"

# Check for stale entries and clean them
check_and_clean_stale() {
    local command_type="$1"  # Either "FETCH_LOCK" or "AT_COMMAND"
    local wait_count=0
    
    while [ $wait_count -lt 6 ]; do
        # Check if our type of entry exists
        if grep -q "\"command\":\"${command_type}\"" "$QUEUE_FILE"; then
            sleep 1
            wait_count=$((wait_count + 1))
        else
            # Entry is gone, we can proceed
            return 0
        fi
    done
    
    # If we get here, entry is stale - remove it
    logger -t signal_metrics "Removing stale ${command_type} entry after ${wait_count}s"
    sed -i "/\"command\":\"${command_type}\"/d" "$QUEUE_FILE"
    return 0
}

# Simplified lock handling
handle_lock() {
    # First check and clean any FETCH_LOCK entries
    check_and_clean_stale "FETCH_LOCK"
    
    # Add our own entry
    printf '{"command":"AT_COMMAND","pid":"%s","timestamp":"%s"}\n' \
        "$$" \
        "$(date '+%H:%M:%S')" >>"$QUEUE_FILE"
    
    # Then check and clean our own entry if it gets stuck
    check_and_clean_stale "AT_COMMAND"
}

# Clean output function
clean_output() {
    local output=""
    read -r line
    
    while read -r line; do
        case "$line" in
            "OK" | "")
                continue
                ;;
            *)
                if [ -n "$output" ]; then
                    output="$output\\n$line"
                else
                    output="$line"
                fi
                ;;
        esac
    done
    
    echo "$output"
}

# Execute AT command
execute_at_command() {
    local COMMAND="$1"
    handle_lock
    local OUTPUT=$(sms_tool at "$COMMAND" -t 4 2>/dev/null | clean_output)
    sed -i "/\"pid\":\"$$\"/d" "$QUEUE_FILE"  # Remove our entry
    echo "$OUTPUT"
}

# Log signal metric
log_signal_metric() {
    [ -f "$PAUSE_FILE" ] && return
    
    local COMMAND="$1"
    local FILENAME="$2"
    local LOGFILE="$LOGDIR/$FILENAME"
    
    mkdir -p "$(dirname "$LOGFILE")"
    
    local TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    local SIGNAL_OUTPUT=$(execute_at_command "$COMMAND")
    
    [ ! -s "$LOGFILE" ] && echo "[]" >"$LOGFILE"
    
    if [ -n "$SIGNAL_OUTPUT" ]; then
        local TEMP_FILE="${LOGFILE}.tmp.$$"
        if jq --arg dt "$TIMESTAMP" \
            --arg out "$SIGNAL_OUTPUT" \
            '. + [{"datetime": $dt, "output": $out}] | .[-'"$MAX_ENTRIES"':]' \
            "$LOGFILE" >"$TEMP_FILE"; then
            mv "$TEMP_FILE" "$LOGFILE"
        else
            rm -f "$TEMP_FILE"
            return 1
        fi
    fi
}

# Main continuous logging function
start_continuous_logging() {
    sleep 20
    logger -t signal_metrics "Starting continuous signal metrics logging (PID: $$)"
    
    trap 'logger -t signal_metrics "Stopping signal metrics logging"; exit 0' INT TERM
    
    while true; do
        if [ ! -f "$PAUSE_FILE" ]; then
            log_signal_metric "AT+QRSRP" "rsrp.json"
            log_signal_metric "AT+QRSRQ" "rsrq.json"
            log_signal_metric "AT+QSINR" "sinr.json"
            log_signal_metric "AT+QGDCNT?;+QGDNRCNT?" "data_usage.json"
        fi
        sleep "$INTERVAL"
    done
}

# Start the continuous logging
start_continuous_logging