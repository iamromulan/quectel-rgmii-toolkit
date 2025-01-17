#!/bin/sh

# Set common headers
echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo "Cache-Control: no-cache, no-store, must-revalidate"
echo ""

# Lock file path
LOCK_FILE="/tmp/hw_details.lock"
LOCK_TIMEOUT=10  # Maximum wait time in seconds

# Function to acquire lock
acquire_lock() {
    local start_time=$(date +%s)
    while [ -e "$LOCK_FILE" ]; do
        # Check if lock is stale (older than LOCK_TIMEOUT seconds)
        if [ -f "$LOCK_FILE" ]; then
            local lock_time=$(stat -c %Y "$LOCK_FILE" 2>/dev/null)
            local current_time=$(date +%s)
            if [ $((current_time - lock_time)) -gt $LOCK_TIMEOUT ]; then
                rm -f "$LOCK_FILE"
                break
            fi
        fi
        
        # Check if we've waited too long
        if [ $(($(date +%s) - start_time)) -gt $LOCK_TIMEOUT ]; then
            error_response "Timeout waiting for lock"
            exit 1
        fi
        
        sleep 0.1
    done
    
    # Create lock file with current PID
    echo $$ > "$LOCK_FILE"
}

# Function to release lock
release_lock() {
    rm -f "$LOCK_FILE"
}

# Function to handle errors and return JSON
error_response() {
    echo "{\"error\": \"$1\"}"
    exit 1
}

# Function to cleanup on exit
cleanup() {
    release_lock
    exit $?
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Function to get memory information
get_memory_info() {
    free_output=$(free -b)
    memory_info=$(echo "$free_output" | awk '/Mem:/ {print "{\"total\": " $2 ", \"used\": " $3 ", \"available\": " $7 "}"}')
    echo "$memory_info"
}

# Function to get ethernet information
get_ethernet_info() {
    interface=${1:-eth0}
    # Check if ethtool is installed
    if ! which ethtool >/dev/null 2>&1; then
        error_response "ethtool not found"
    fi
    
    # Check if interface exists
    if ! ip link show "$interface" >/dev/null 2>&1; then
        error_response "Interface $interface not found"
    fi
    
    # Run ethtool and capture output
    ethtool_output=$(ethtool "$interface" 2>/dev/null) || error_response "Failed to get ethernet information"
    
    # Extract values using sed instead of grep -P
    speed=$(echo "$ethtool_output" | sed -n 's/.*Speed: \([^[:space:]]*\).*/\1/p' || echo "Unknown")
    link_status=$(echo "$ethtool_output" | sed -n 's/.*Link detected: \(yes\|no\).*/\1/p' || echo "unknown")
    auto_negotiation=$(echo "$ethtool_output" | sed -n 's/.*Auto-negotiation: \(on\|off\).*/\1/p' || echo "unknown")
    
    # Output JSON
    echo "{\"link_speed\":\"$speed\",\"link_status\":\"$link_status\",\"auto_negotiation\":\"$auto_negotiation\"}"
}

# Main execution
# Acquire lock before proceeding
acquire_lock

# Parse query string for type and interface
type=$(echo "$QUERY_STRING" | sed -n 's/.*type=\([^&]*\).*/\1/p')
interface=$(echo "$QUERY_STRING" | sed -n 's/.*interface=\([^&]*\).*/\1/p')

# Default interface if not specified
[ -z "$interface" ] && interface="eth0"

# Convert type to lowercase using tr
type=$(echo "$type" | tr '[:upper:]' '[:lower:]')

# Check type parameter and call appropriate function
case "$type" in
    "memory")
        get_memory_info
        ;;
    "eth")
        get_ethernet_info "$interface"
        ;;
    *)
        error_response "Invalid type. Use 'memory' or 'eth'"
        ;;
esac

# Lock will be automatically released by the cleanup trap