#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# list.sh — CGI Endpoint: List Custom Connection Scenarios
# =============================================================================
# Returns all custom scenario definitions stored on the device, plus the
# active scenario ID. No modem interaction — reads from flash only.
#
# Storage: /etc/qmanager/scenarios/ directory with one JSON file per scenario.
#
# Endpoint: GET /cgi-bin/quecmanager/scenarios/list.sh
# Response: {
#   "scenarios": [ { "id":"custom-...", "name":"...", ... }, ... ],
#   "active_scenario_id": "balanced"
# }
#
# Install location: /www/cgi-bin/quecmanager/scenarios/list.sh
# =============================================================================

# --- Configuration -----------------------------------------------------------
SCENARIOS_DIR="/etc/qmanager/scenarios"
ACTIVE_SCENARIO_FILE="/etc/qmanager/active_scenario"

qlog_init "cgi_scenario_list"
cgi_headers
cgi_handle_options

# --- Read active scenario ----------------------------------------------------
ACTIVE_ID=""
if [ -f "$ACTIVE_SCENARIO_FILE" ]; then
    ACTIVE_ID=$(cat "$ACTIVE_SCENARIO_FILE" 2>/dev/null | tr -d ' \n\r')
fi
[ -z "$ACTIVE_ID" ] && ACTIVE_ID="balanced"

# --- Collect custom scenarios from individual JSON files ----------------------
mkdir -p "$SCENARIOS_DIR" 2>/dev/null

# Slurp all scenario JSON files into an array; build response with jq
SCENARIOS=$(cat "$SCENARIOS_DIR"/*.json 2>/dev/null | jq -sc '.' 2>/dev/null)
[ -z "$SCENARIOS" ] && SCENARIOS="[]"

jq -n --argjson s "$SCENARIOS" --arg id "$ACTIVE_ID" \
    '{"scenarios":$s,"active_scenario_id":$id}'
