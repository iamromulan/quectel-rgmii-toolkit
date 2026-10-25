#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# speedtest_check.sh — CGI Endpoint: Speedtest Availability Check
# =============================================================================
# Returns whether speedtest-cli (Ookla) is installed and executable.
# Called once on component mount to enable/disable the speedtest button.
#
# Endpoint: GET /cgi-bin/quecmanager/at_cmd/speedtest_check.sh
# Response: {"available": true} or {"available": false}
#
# Install location: /www/cgi-bin/quecmanager/at_cmd/speedtest_check.sh
# =============================================================================

qlog_init "cgi_speedtest_check"
cgi_headers
cgi_handle_options

# --- Check for speedtest binary ----------------------------------------------
if command -v speedtest >/dev/null 2>&1; then
    jq -n '{"available":true}'
else
    jq -n '{"available":false}'
fi
