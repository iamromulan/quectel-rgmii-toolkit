#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# fetch_events.sh — CGI Endpoint for Recent Activities / Network Events
# =============================================================================
# Serves the network events NDJSON file as a JSON array to the frontend.
# Zero modem contact — reads from RAM only.
#
# The events file is NDJSON (one JSON object per line). This script converts
# it to a proper JSON array for the frontend.
#
# Endpoint: GET /cgi-bin/quecmanager/at_cmd/fetch_events.sh
# Response: application/json
#
# Install location: /www/cgi-bin/quecmanager/at_cmd/fetch_events.sh
# =============================================================================

EVENTS_FILE="/tmp/qmanager_events.json"

qlog_init "cgi_fetch_events"
cgi_headers
cgi_handle_options

serve_ndjson_as_array "$EVENTS_FILE"
