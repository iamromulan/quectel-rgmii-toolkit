#!/bin/sh
# overview.sh — Public, unauthenticated overview endpoint.
# Projects an allowlisted subset of /tmp/qmanager_status.json.
# This is the ENTIRE unauth attack surface for modem status —
# do not add fields without a security review.
#
# Endpoint: GET /cgi-bin/quecmanager/public/overview.sh
# Response: application/json
#
# Install location: /www/cgi-bin/quecmanager/public/overview.sh

_SKIP_AUTH=1
. /usr/lib/qmanager/cgi_base.sh
qlog_init "cgi_public_overview"
cgi_headers
cgi_handle_options

# UI heartbeat — any overview hit is activity (including setup_required /
# unavailable paths). The poller reads this epoch to keep AT reads at the Active
# cadence while a browser is open (adaptive backoff).
# Written to a temp file then renamed, so the poller never reads a half-written epoch.
date +%s > /tmp/qmanager_ui_active.$$ 2>/dev/null && mv -f /tmp/qmanager_ui_active.$$ /tmp/qmanager_ui_active 2>/dev/null || rm -f /tmp/qmanager_ui_active.$$

STATUS_FILE="/tmp/qmanager_status.json"

# Fresh-install gate: if no password is set, frontend must reroute to /setup/.
if is_setup_required; then
    jq -n '{"state":"setup_required"}'
    exit 0
fi

# Poller hasn't produced a snapshot yet (boot, or poller crashed).
if [ ! -f "$STATUS_FILE" ] || [ ! -s "$STATUS_FILE" ]; then
    jq -n '{"state":"unavailable","reason":"poller_not_started"}'
    exit 0
fi

# Allowlist projection. Every field below is the entire unauth contract.
jq '{
  state: "ok",
  timestamp: .timestamp,
  modem_reachable: .modem_reachable,
  uptime_seconds: (.device.uptime_seconds // 0),
  network: {
    type: .network.type,
    service_status: .network.service_status,
    carrier: .network.carrier,
    bands: [(.network.carrier_components // [])[] | select(.band != null and .band != "") | {band: .band, bandwidth_mhz: (.bandwidth_mhz // 0), pci: .pci, rsrp: .rsrp, rsrq: .rsrq, sinr: .sinr}],
    lte_state: .lte.state,
    nr_state: .nr.state
  },
  signal: {
    rsrp: (if .lte.rsrp != null then .lte.rsrp elif .nr.rsrp != null then .nr.rsrp else null end),
    rsrq: (if .lte.rsrq != null then .lte.rsrq elif .nr.rsrq != null then .nr.rsrq else null end),
    sinr: (if .lte.sinr != null then .lte.sinr elif .nr.sinr != null then .nr.sinr else null end)
  },
  temperature: (.device.temperature // null)
}' "$STATUS_FILE" 2>/dev/null || jq -n '{"state":"unavailable","reason":"parse_error"}'
