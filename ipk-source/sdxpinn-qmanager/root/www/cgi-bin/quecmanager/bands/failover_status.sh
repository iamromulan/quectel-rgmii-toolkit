#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh
# =============================================================================
# failover_status.sh — CGI Endpoint: Get Failover State (Lightweight)
# =============================================================================
# Reads only filesystem flags — zero modem contact. Designed for frequent
# polling (~2-3s) by the frontend after a band lock to detect when the
# failover watcher has completed its check.
#
# Endpoint: GET /cgi-bin/quecmanager/bands/failover_status.sh
# Response: {
#   "enabled": true,
#   "activated": false,
#   "watcher_running": true
# }
#
# Install location: /www/cgi-bin/quecmanager/bands/failover_status.sh
# =============================================================================

# --- Configuration -----------------------------------------------------------
FAILOVER_ENABLED_FILE="/etc/qmanager/band_failover_enabled"
FAILOVER_ACTIVATED_FLAG="/tmp/qmanager_band_failover"
WATCHER_PID_FILE="/tmp/qmanager_band_failover.pid"

qlog_init "cgi_band_failover_status"
cgi_headers
cgi_handle_options

# --- Read failover enabled flag (persistent, flash) --------------------------
enabled="false"
if [ -f "$FAILOVER_ENABLED_FILE" ]; then
    val=$(cat "$FAILOVER_ENABLED_FILE" 2>/dev/null | tr -d ' \n\r')
    [ "$val" = "1" ] && enabled="true"
fi

# --- Read failover activated flag (RAM, written by watcher) ------------------
activated="false"
if [ -f "$FAILOVER_ACTIVATED_FLAG" ]; then
    activated="true"
fi

# --- Check if watcher process is still running -------------------------------
watcher_running="false"
if [ -f "$WATCHER_PID_FILE" ]; then
    watcher_pid=$(qm_read_pid "$WATCHER_PID_FILE" qmanager_band_failover)
    if [ -n "$watcher_pid" ]; then
        watcher_running="true"
    fi
fi

# --- Response ----------------------------------------------------------------
jq -n --argjson e "$enabled" --argjson a "$activated" --argjson w "$watcher_running" \
    '{"enabled":$e,"activated":$a,"watcher_running":$w}'
