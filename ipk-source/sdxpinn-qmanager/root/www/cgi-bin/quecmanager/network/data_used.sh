#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# data_used.sh — CGI Endpoint: Data Used counter (GET)
# =============================================================================
# Serves the RAM mirror the poller's data_used.sh lib rewrites every 30 s
# (docs/features/data-used.md). Read-only; the poller is the only writer.
#
# GET → {"success":true,"available":true,"rx_bytes":N,"tx_bytes":N,
#        "since":EPOCH|0,"updated":EPOCH|0,"iface_present":BOOL,
#        "source":"wds"|"netdev","stale":BOOL}
#       {"success":true,"available":false} before the poller's first sample.
# rx = download, tx = upload. since/updated are 0 while the clock reads 1970.
# source = the counter of the last sample: the modem's QMI WDS counter, or the
# rmnet_ipa0 fallback (also for mirrors written before the field existed).
# stale = the mirror has not been rewritten for STALE_SECONDS (poller stopped).
#
# Endpoint: GET /cgi-bin/quecmanager/network/data_used.sh
# Install location: /www/cgi-bin/quecmanager/network/data_used.sh
# =============================================================================

qlog_init "cgi_data_used"
cgi_headers
cgi_handle_options

MIRROR="/var/run/qmanager/data_used.json"
STALE_SECONDS=90

if [ "$REQUEST_METHOD" != "GET" ]; then
    cgi_method_not_allowed
    exit 0
fi

if [ ! -f "$MIRROR" ]; then
    jq -n '{success:true, available:false}'
    exit 0
fi

mtime=$(stat -c %Y "$MIRROR" 2>/dev/null)
now=$(date +%s)
case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
stale=false
[ $((now - mtime)) -gt "$STALE_SECONDS" ] && stale=true

out=$(jq -c --argjson stale "$stale" '{
    success: true,
    available: true,
    rx_bytes: (.rx_bytes // 0),
    tx_bytes: (.tx_bytes // 0),
    since: (.since // 0),
    updated: (.updated // 0),
    iface_present: (.iface_present // false),
    source: (if .source == "wds" then "wds" else "netdev" end),
    stale: $stale
}' "$MIRROR" 2>/dev/null)

if [ -z "$out" ]; then
    qlog_warn "data_used mirror unreadable"
    jq -n '{success:true, available:false}'
    exit 0
fi
printf '%s\n' "$out"
