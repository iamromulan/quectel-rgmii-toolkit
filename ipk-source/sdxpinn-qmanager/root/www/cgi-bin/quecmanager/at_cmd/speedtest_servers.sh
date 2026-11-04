#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# speedtest_servers.sh — CGI Endpoint: List Nearby Speedtest Servers
# =============================================================================
# Runs `speedtest --servers -f json`, extracts the server list, and returns it.
#
# Endpoint: GET /cgi-bin/quecmanager/at_cmd/speedtest_servers.sh
# Install location: /www/cgi-bin/quecmanager/at_cmd/speedtest_servers.sh
# =============================================================================

qlog_init "cgi_speedtest_servers"
cgi_headers
cgi_handle_options

if [ "$REQUEST_METHOD" != "GET" ]; then
    cgi_error "method_not_allowed" "Use GET"
    exit 0
fi

if ! command -v speedtest >/dev/null 2>&1; then
    cgi_error "not_installed" "speedtest-cli is not installed"
    exit 0
fi

# Set environment the Ookla binary needs (without sourcing /etc/profile)
export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export LOGNAME="${LOGNAME:-root}"
export TMPDIR="${TMPDIR:-/tmp}"
export LANG="${LANG:-C}"
export LC_ALL="${LC_ALL:-C}"
export TERM="${TERM:-xterm}"
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# Run server list to temp file (takes 2-5 seconds)
OUTFILE="/tmp/qmanager_speedtest_servers.json"
speedtest --servers --accept-license --accept-gdpr -f json > "$OUTFILE" 2>/dev/null

if [ ! -s "$OUTFILE" ]; then
    rm -f "$OUTFILE"
    cgi_error "list_failed" "Failed to fetch server list"
    exit 0
fi

# Extract .servers array from {"type":"serverList","servers":[...]}
SERVERS=$(jq -c '.servers' "$OUTFILE" 2>/dev/null)
rm -f "$OUTFILE"

if [ -z "$SERVERS" ] || [ "$SERVERS" = "null" ]; then
    cgi_error "list_failed" "No servers found in response"
    exit 0
fi

printf '{"success":true,"servers":%s}' "$SERVERS"
