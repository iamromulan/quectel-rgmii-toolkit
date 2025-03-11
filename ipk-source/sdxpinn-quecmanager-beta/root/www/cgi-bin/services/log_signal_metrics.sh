#!/bin/sh
# Configuration
LOGDIR="/www/signal_graphs"
MAX_ENTRIES=10
INTERVAL=60
QUEUE_DIR="/tmp/at_queue"
TOKEN_FILE="$QUEUE_DIR/token"
LOCK_FILE="/tmp/signal_metrics.lock"
METRICS_PID_FILE="/tmp/signal_metrics.pid"
MAX_TOKEN_WAIT=5  # seconds to wait for token acquisition

# Ensure required directories exist
mkdir -p "$LOGDIR" "$QUEUE_DIR"

# Check if another instance is running
check_running() {
    if [ -f "$METRICS_PID_FILE" ]; then
        pid=$(cat "$METRICS_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        rm -f "$METRICS_PID_FILE" 2>/dev/null
    fi
    return 1
}

# Acquire token directly (minimized version)
acquire_token() {
    local metrics_id="METRICS_$(date +%s)_$$"
    local priority=20  # Lowest priority for metrics
    local max_attempts=20
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        # Check if token exists
        if [ -f "$TOKEN_FILE" ]; then
            # Check current token
            local current_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id' 2>/dev/null)
            local current_priority=$(cat "$TOKEN_FILE" | jsonfilter -e '@.priority' 2>/dev/null)
            local timestamp=$(cat "$TOKEN_FILE" | jsonfilter -e '@.timestamp' 2>/dev/null)
            local current_time=$(date +%s)
            
            # Check for expired token
            if [ $((current_time - timestamp)) -gt 30 ] || [ -z "$current_holder" ]; then
                rm -f "$TOKEN_FILE" 2>/dev/null
            elif [ $priority -lt $current_priority ]; then
                rm -f "$TOKEN_FILE" 2>/dev/null
            else
                # Wait and try again
                sleep 0.5
                attempt=$((attempt + 1))
                continue
            fi
        fi
        
        # Try to create token
        echo "{\"id\":\"$metrics_id\",\"priority\":$priority,\"timestamp\":$(date +%s)}" > "$TOKEN_FILE" 2>/dev/null
        chmod 644 "$TOKEN_FILE" 2>/dev/null
        
        # Verify we got it
        local holder=$(cat "$TOKEN_FILE" 2>/dev/null | jsonfilter -e '@.id' 2>/dev/null)
        if [ "$holder" = "$metrics_id" ]; then
            echo "$metrics_id"
            return 0
        fi
        
        sleep 0.5
        attempt=$((attempt + 1))
    done
    
    return 1
}

# Release token directly
release_token() {
    local metrics_id="$1"
    
    if [ -f "$TOKEN_FILE" ]; then
        local current_holder=$(cat "$TOKEN_FILE" | jsonfilter -e '@.id' 2>/dev/null)
        if [ "$current_holder" = "$metrics_id" ]; then
            rm -f "$TOKEN_FILE" 2>/dev/null
        fi
    fi
}

# Execute AT command directly
execute_at_command() {
    local CMD="$1"
    sms_tool at "$CMD" -t 3 2>/dev/null
}

# Process all metrics commands with a single token
process_all_metrics() {
    # Try to get token
    local metrics_id=$(acquire_token)
    if [ -z "$metrics_id" ]; then
        logger -t at_queue -p daemon.warn "Could not acquire token for metrics - will try again later"
        return 1
    fi
    
    logger -t at_queue -p daemon.info "Processing all metrics with token $metrics_id"
    
    # Execute all metrics commands with the single token
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # RSRP
    local rsrp_output=$(execute_at_command "AT+QRSRP")
    if [ -n "$rsrp_output" ] && echo "$rsrp_output" | grep -q "QRSRP"; then
        local logfile="$LOGDIR/rsrp.json"
        [ ! -s "$logfile" ] && echo "[]" > "$logfile"
        
        local temp_file="${logfile}.tmp.$$"
        jq --arg dt "$timestamp" \
           --arg out "$rsrp_output" \
           '. + [{"datetime": $dt, "output": $out}] | .[-'"$MAX_ENTRIES"':]' \
           "$logfile" > "$temp_file" 2>/dev/null && mv "$temp_file" "$logfile"
        chmod 644 "$logfile"
    fi
    
    sleep 0.5
    
    # RSRQ
    local rsrq_output=$(execute_at_command "AT+QRSRQ")
    if [ -n "$rsrq_output" ] && echo "$rsrq_output" | grep -q "QRSRQ"; then
        local logfile="$LOGDIR/rsrq.json"
        [ ! -s "$logfile" ] && echo "[]" > "$logfile"
        
        local temp_file="${logfile}.tmp.$$"
        jq --arg dt "$timestamp" \
           --arg out "$rsrq_output" \
           '. + [{"datetime": $dt, "output": $out}] | .[-'"$MAX_ENTRIES"':]' \
           "$logfile" > "$temp_file" 2>/dev/null && mv "$temp_file" "$logfile"
        chmod 644 "$logfile"
    fi
    
    sleep 0.5
    
    # SINR
    local sinr_output=$(execute_at_command "AT+QSINR")
    if [ -n "$sinr_output" ] && echo "$sinr_output" | grep -q "QSINR"; then
        local logfile="$LOGDIR/sinr.json"
        [ ! -s "$logfile" ] && echo "[]" > "$logfile"
        
        local temp_file="${logfile}.tmp.$$"
        jq --arg dt "$timestamp" \
           --arg out "$sinr_output" \
           '. + [{"datetime": $dt, "output": $out}] | .[-'"$MAX_ENTRIES"':]' \
           "$logfile" > "$temp_file" 2>/dev/null && mv "$temp_file" "$logfile"
        chmod 644 "$logfile"
    fi
    
    sleep 0.5
    
    # Data usage
    local usage_output=$(execute_at_command "AT+QGDCNT?;+QGDNRCNT?")
    if [ -n "$usage_output" ] && echo "$usage_output" | grep -q "QGDCNT\|QGDNRCNT"; then
        local logfile="$LOGDIR/data_usage.json"
        [ ! -s "$logfile" ] && echo "[]" > "$logfile"
        
        local temp_file="${logfile}.tmp.$$"
        jq --arg dt "$timestamp" \
           --arg out "$usage_output" \
           '. + [{"datetime": $dt, "output": $out}] | .[-'"$MAX_ENTRIES"':]' \
           "$logfile" > "$temp_file" 2>/dev/null && mv "$temp_file" "$logfile"
        chmod 644 "$logfile"
    fi
    
    # Release token
    release_token "$metrics_id"
    logger -t at_queue -p daemon.info "Metrics processing completed"
    return 0
}

# Main continuous logging function with proper locking
start_continuous_logging() {
    # Check if already running
    if check_running; then
        logger -t at_queue -p daemon.error "Signal metrics logging already running"
        exit 1
    fi
    
    # Store PID
    echo "$$" > "$METRICS_PID_FILE"
    chmod 644 "$METRICS_PID_FILE"
    
    sleep 20  # Initial delay to allow system startup
    logger -t at_queue -p daemon.info "Starting continuous signal metrics logging (PID: $$)"

    trap 'logger -t at_queue -p daemon.info "Stopping signal metrics logging"; rm -f "$METRICS_PID_FILE"; exit 0' INT TERM

    while true; do
        process_all_metrics
        sleep "$INTERVAL"
    done
}

# Start the continuous logging
start_continuous_logging