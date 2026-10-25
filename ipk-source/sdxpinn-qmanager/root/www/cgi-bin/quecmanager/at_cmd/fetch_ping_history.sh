#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# fetch_ping_history.sh — CGI Endpoint for Ping History Chart Data
# =============================================================================
# Serves the ping history NDJSON file as a JSON array.
# Zero modem contact — reads from RAM only.
#
# The ping history file is NDJSON (one JSON object per line). This script
# converts it to a proper JSON array for the frontend.
#
# Each line format:
#   {"ts":1707900000,"lat":34.2,"avg":38.1,"min":12.3,"max":95.7,"loss":0,"jit":4.8}
#
# Endpoint: GET /cgi-bin/quecmanager/at_cmd/fetch_ping_history.sh
# Response: application/json
#
# Install location: /www/cgi-bin/quecmanager/at_cmd/fetch_ping_history.sh
# =============================================================================

PING_HISTORY_FILE="/tmp/qmanager_ping_history.json"

qlog_init "cgi_fetch_ping_history"
cgi_headers
cgi_handle_options

serve_ndjson_as_array "$PING_HISTORY_FILE"
