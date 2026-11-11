#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# fetch_data.sh — CGI Endpoint for Dashboard Data
# =============================================================================
# Serves the cached JSON state file to the frontend.
# Zero modem contact — reads from RAM only.
#
# Endpoint: GET /cgi-bin/quecmanager/at_cmd/fetch_data.sh
# Response: application/json
#
# Install location: /www/cgi-bin/quecmanager/at_cmd/fetch_data.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_fetch"
cgi_headers
cgi_handle_options

# UI heartbeat — any dashboard fetch is activity. The poller reads this epoch to
# keep AT reads at the Active cadence while a browser is open (adaptive backoff).
# Written to a temp file then renamed, so the poller never reads a half-written epoch.
date +%s > /tmp/qmanager_ui_active.$$ 2>/dev/null && mv -f /tmp/qmanager_ui_active.$$ /tmp/qmanager_ui_active 2>/dev/null || rm -f /tmp/qmanager_ui_active.$$

CACHE_FILE="/tmp/qmanager_status.json"

# --- Serve the cache ---------------------------------------------------------
if [ -f "$CACHE_FILE" ]; then
    cat "$CACHE_FILE"
else
    qlog_warn "Cache file not found, returning fallback JSON"
    # Cache doesn't exist yet (poller hasn't started or first boot)
    cat << 'FALLBACK'
{
  "timestamp": 0,
  "system_state": "initializing",
  "modem_reachable": false,
  "last_successful_poll": 0,
  "errors": ["poller_not_started"],
  "network": {
    "type": "",
    "sim_slot": 1,
    "carrier": "",
    "service_status": "unknown",
    "ca_active": false,
    "ca_count": 0
  },
  "lte": { "state": "unknown", "band": "", "earfcn": null, "bandwidth": null, "pci": null, "rsrp": null, "rsrq": null, "sinr": null, "rssi": null },
  "nr": { "state": "unknown", "band": "", "arfcn": null, "pci": null, "rsrp": null, "rsrq": null, "sinr": null, "scs": null },
  "device": {
    "temperature": null, "cpu_usage": 0, "memory_used_mb": 0, "memory_total_mb": 0,
    "uptime_seconds": 0, "conn_uptime_seconds": 0,
    "firmware": "", "build_date": "", "manufacturer": "", "model": "",
    "imei": "", "imsi": "", "iccid": "", "phone_number": "",
    "lte_category": "", "mimo": ""
  }
}
FALLBACK
fi
