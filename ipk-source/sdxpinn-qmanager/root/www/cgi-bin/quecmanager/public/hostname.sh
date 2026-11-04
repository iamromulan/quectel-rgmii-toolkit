#!/bin/sh
# hostname.sh — Public, unauthenticated device-identity endpoint.
# Returns the modem's hostname so the pre-auth login screen can show which
# device the user is about to log into.
#
# This is part of the UNAUTH attack surface alongside public/overview.sh.
# The entire contract is a single string field; do not add fields here
# without a security review.
#
# Endpoint: GET /cgi-bin/quecmanager/public/hostname.sh
# Response: application/json  ->  { "hostname": "<string>" }
#
# Source priority:
#   1. UCI                       (system.@system[0].hostname)  canonical
#   2. /proc/sys/kernel/hostname (fallback for stripped images)
#   3. ""                        (graceful — frontend hides the pill)
#
# Always responds HTTP 200. An empty string is the explicit "no name set"
# signal that drives the frontend's silent-omission state.
#
# Install location: /www/cgi-bin/quecmanager/public/hostname.sh

_SKIP_AUTH=1
. /usr/lib/qmanager/cgi_base.sh
qlog_init "cgi_public_hostname"
cgi_headers

HN=$(uci -q get system.@system[0].hostname 2>/dev/null)
if [ -z "$HN" ] && [ -r /proc/sys/kernel/hostname ]; then
    HN=$(cat /proc/sys/kernel/hostname 2>/dev/null)
fi

# Strip whitespace/newlines defensively. RFC-1123 hostnames are <=63 chars;
# clamp to that to prevent a misconfigured /etc/hostname from blowing up the
# pre-auth payload.
HN=$(printf '%s' "$HN" | tr -d '\r\n' | cut -c1-63)

jq -n --arg hostname "$HN" '{hostname:$hostname}'
