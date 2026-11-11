#!/bin/sh
# units.sh — Public, unauthenticated unit-preference endpoint.
# Returns the user's temperature/distance unit preference so the pre-auth
# splash ("/") can render the modem temperature in the user's unit before
# login. Unit prefs are non-sensitive (celsius|fahrenheit, km|miles).
#
# This is part of the UNAUTH attack surface alongside public/overview.sh and
# public/hostname.sh. The entire contract is these two string fields; do not
# add fields here without a security review — quecmanager.settings holds
# other, non-public settings (scheduled reboot) in the same section.
#
# Mirrors the GET read path of system/settings.sh: same UCI keys, same
# defaults. Each value is allowlisted, so a hand-edited UCI value can never be
# echoed to an unauthenticated caller — anything unexpected reads as default.
#
# Zero writes: deliberately does NOT seed quecmanager.settings when missing
# (system/settings.sh does, behind auth); a missing section reads as defaults.
#
# Endpoint: GET /cgi-bin/quecmanager/public/units.sh
# Response: application/json  ->  { "settings": { "temp_unit": "...", "distance_unit": "..." } }
# Any other method: the standard method_not_allowed envelope.
#
# Install location: /www/cgi-bin/quecmanager/public/units.sh

_SKIP_AUTH=1
. /usr/lib/qmanager/cgi_base.sh
qlog_init "cgi_public_units"
cgi_headers
cgi_handle_options

if [ "$REQUEST_METHOD" != "GET" ]; then
    cgi_method_not_allowed
fi

TEMP_UNIT=$(uci -q get quecmanager.settings.temp_unit 2>/dev/null)
case "$TEMP_UNIT" in
    celsius|fahrenheit) ;;
    *) TEMP_UNIT="celsius" ;;
esac

DIST_UNIT=$(uci -q get quecmanager.settings.distance_unit 2>/dev/null)
case "$DIST_UNIT" in
    km|miles) ;;
    *) DIST_UNIT="km" ;;
esac

jq -n --arg t "$TEMP_UNIT" --arg d "$DIST_UNIT" \
    '{settings:{temp_unit:$t, distance_unit:$d}}'
