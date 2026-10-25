#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# failover_status.sh — CGI Endpoint: Get Tower Failover State (Lightweight)
# =============================================================================
# Reads only filesystem flags — zero modem contact. Designed for frequent
# polling (~2-3s) by the frontend after a tower lock to detect when the
# failover watcher has completed its check.
#
# Endpoint: GET /cgi-bin/quecmanager/tower/failover_status.sh
# Install location: /www/cgi-bin/quecmanager/tower/failover_status.sh
# =============================================================================

# --- Configuration -----------------------------------------------------------
TOWER_CONFIG_FILE="/etc/qmanager/tower_lock.json"
FAILOVER_ACTIVATED_FLAG="/tmp/qmanager_tower_failover"
WATCHER_PID_FILE="/tmp/qmanager_tower_failover.pid"

qlog_init "cgi_tower_failover_status"
cgi_headers
cgi_handle_options

# --- Load tower lock library -------------------------------------------------
if [ -f /usr/lib/qmanager/tower_lock_mgr.sh ]; then
    . /usr/lib/qmanager/tower_lock_mgr.sh
else
    cgi_error "internal_error" "tower lock library unavailable"
    exit 0
fi

# --- Read failover enabled from config (flash) ------------------------------
# NOTE: Do not use `// false` — jq's alternative operator treats `false` as
# falsy, so `false // false` always returns the alternative. Use direct access.
enabled="false"
if [ -f "$TOWER_CONFIG_FILE" ]; then
    val=$(jq -r '.failover.enabled' "$TOWER_CONFIG_FILE" 2>/dev/null)
    [ "$val" = "true" ] && enabled="true"
fi

# --- Read failover activated flag (RAM, written by watcher) ------------------
activated="false"
if [ -f "$FAILOVER_ACTIVATED_FLAG" ]; then
    activated="true"
fi

# --- Read lock active state (drives self-heal decision) ----------------------
lte_active="false"
nr_active="false"
if [ -f "$TOWER_CONFIG_FILE" ]; then
    lte_val=$(jq -r '.lte.enabled' "$TOWER_CONFIG_FILE" 2>/dev/null)
    [ "$lte_val" = "true" ] && lte_active="true"
    nr_val=$(jq -r '.nr_sa.enabled' "$TOWER_CONFIG_FILE" 2>/dev/null)
    [ "$nr_val" = "true" ] && nr_active="true"
fi

# --- Check if watcher process is still running -------------------------------
watcher_running="false"
if command -v tower_get_running_failover_pid >/dev/null 2>&1; then
    if watcher_pid=$(tower_get_running_failover_pid); then
        [ -n "$watcher_pid" ] && watcher_running="true"
    fi
elif [ -f "$WATCHER_PID_FILE" ]; then
    watcher_pid=$(cat "$WATCHER_PID_FILE" 2>/dev/null | tr -d ' \n\r')
    if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then
        watcher_running="true"
    fi
fi

# --- Self-heal: orphan daemon with no active lock ---------------------------
# If a watcher is running but neither lock is configured as enabled, the
# daemon is orphaned (unlock left it behind, or config was edited). Kill it
# and clear the activation flag so the UI stops reading "Monitoring".
if [ "$watcher_running" = "true" ] && [ "$lte_active" != "true" ] && [ "$nr_active" != "true" ]; then
    qlog_warn "Orphan failover daemon detected with no active lock — self-healing"
    /etc/init.d/qmanager_tower_failover stop 2>/dev/null
    rm -f "$FAILOVER_ACTIVATED_FLAG" "$WATCHER_PID_FILE"
    watcher_running="false"
    activated="false"
fi

# --- Response ----------------------------------------------------------------
jq -n --argjson e "$enabled" --argjson a "$activated" --argjson w "$watcher_running" \
    '{enabled:$e, activated:$a, watcher_running:$w}'
