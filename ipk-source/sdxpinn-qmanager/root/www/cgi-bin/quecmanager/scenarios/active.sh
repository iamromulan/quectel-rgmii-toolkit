#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# active.sh — CGI Endpoint: Get Active Connection Scenario
# =============================================================================
# Returns the currently active connection scenario ID.
# Defaults to "balanced" if no scenario has been explicitly activated.
#
# Endpoint: GET /cgi-bin/quecmanager/scenarios/active.sh
# Response: {"active_scenario_id":"balanced"}
#
# Install location: /www/cgi-bin/quecmanager/scenarios/active.sh
# =============================================================================

# --- Configuration -----------------------------------------------------------
ACTIVE_SCENARIO_FILE="/etc/qmanager/active_scenario"

qlog_init "cgi_scenario_active"
cgi_headers
cgi_handle_options

# --- Read active scenario ----------------------------------------------------
ACTIVE_ID=""
if [ -f "$ACTIVE_SCENARIO_FILE" ]; then
    ACTIVE_ID=$(cat "$ACTIVE_SCENARIO_FILE" 2>/dev/null | tr -d ' \n\r')
fi

# Default to balanced if not set or empty
[ -z "$ACTIVE_ID" ] && ACTIVE_ID="balanced"

jq -n --arg id "$ACTIVE_ID" '{"active_scenario_id":$id}'
