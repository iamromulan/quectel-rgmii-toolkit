#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# fetch_signal_history.sh — CGI Endpoint for Signal History Chart Data
# =============================================================================
# Serves the per-antenna signal history NDJSON file as a JSON array.
# Zero modem contact — reads from RAM only.
#
# The signal history file is NDJSON (one JSON object per line). This script
# converts it to a proper JSON array for the frontend.
#
# Each line format:
#   {"ts":1707900000,"lte_rsrp":[-95,-97,null,null],...}
#
# Endpoint: GET /cgi-bin/quecmanager/at_cmd/fetch_signal_history.sh
# Response: application/json
#
# Install location: /www/cgi-bin/quecmanager/at_cmd/fetch_signal_history.sh
# =============================================================================

SIGNAL_HISTORY_FILE="/tmp/qmanager_signal_history.json"

qlog_init "cgi_fetch_signal_history"
cgi_headers
cgi_handle_options

serve_ndjson_as_array "$SIGNAL_HISTORY_FILE"
