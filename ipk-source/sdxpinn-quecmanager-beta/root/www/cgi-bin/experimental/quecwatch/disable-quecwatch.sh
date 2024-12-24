#!/bin/sh

# Configuration and log directories
CONFIG_DIR="/etc/quecmanager/quecwatch"
QUECWATCH_SCRIPT="${CONFIG_DIR}/quecwatch.sh"
RCLOCAL="/etc/rc.local"
LOG_DIR="/tmp/log/quecwatch"
DEBUG_LOG_FILE="${LOG_DIR}/debug.log"

# Log directory for cleaning process
CLEANUP_LOG_FILE="${LOG_DIR}/cleanup.log"

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Function to log cleanup events
log_cleanup() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${CLEANUP_LOG_FILE}"
}

# Default response headers
echo "Content-type: application/json"
echo ""

# Cleanup function
cleanup_quecwatch() {
    # Start logging cleanup process
    log_cleanup "Starting QuecWatch cleanup process"

    # Stop any running QuecWatch processes
    log_cleanup "Stopping QuecWatch processes"
    pkill -f "${QUECWATCH_SCRIPT}" >> "${CLEANUP_LOG_FILE}" 2>&1

    # Remove QuecWatch script from rc.local
    if [ -f "${RCLOCAL}" ]; then
        log_cleanup "Removing QuecWatch entries from rc.local"
        sed -i '\|/etc/quecmanager/quecwatch/quecwatch.sh|d' "${RCLOCAL}" >> "${CLEANUP_LOG_FILE}" 2>&1
    fi

    # Remove configuration directory
    if [ -d "${CONFIG_DIR}" ]; then
        log_cleanup "Removing configuration directory: ${CONFIG_DIR}"
        rm -rf "${CONFIG_DIR}" >> "${CLEANUP_LOG_FILE}" 2>&1
    fi

    # Remove log directory
    if [ -d "${LOG_DIR}" ]; then
        log_cleanup "Removing log directory: ${LOG_DIR}"
        rm -rf "${LOG_DIR}" >> "${CLEANUP_LOG_FILE}" 2>&1
    fi

    log_cleanup "QuecWatch cleanup completed successfully"
    
    # Optional: Output JSON response
    echo '{"status": "success", "message": "QuecWatch disabled and removed"}'
}

# Execute cleanup
cleanup_quecwatch

exit 0