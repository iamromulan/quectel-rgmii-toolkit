#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# delete.sh — CGI Endpoint: Delete Custom Connection Scenario
# =============================================================================
# Removes a custom scenario definition by ID. If the deleted scenario was
# active, resets the active scenario to "balanced".
#
# Endpoint: POST /cgi-bin/quecmanager/scenarios/delete.sh
# Request body: {"id": "custom-..."}
# Response: {"success":true,"id":"custom-..."}
#
# Install location: /www/cgi-bin/quecmanager/scenarios/delete.sh
# =============================================================================

# --- Configuration -----------------------------------------------------------
SCENARIOS_DIR="/etc/qmanager/scenarios"
ACTIVE_SCENARIO_FILE="/etc/qmanager/active_scenario"

qlog_init "cgi_scenario_delete"
cgi_headers
cgi_handle_options

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Read POST body ----------------------------------------------------------
cgi_read_post

# --- Extract scenario ID from JSON body ---------------------------------------
SCENARIO_ID=$(printf '%s' "$POST_DATA" | jq -r '.id // empty')

if [ -z "$SCENARIO_ID" ]; then
    cgi_error "no_id" "Missing id field in request body"
    exit 0
fi

# --- Sanitize ID (prevent path traversal) ------------------------------------
case "$SCENARIO_ID" in
    custom-[0-9]*)
        # Valid format
        ;;
    *)
        cgi_error "invalid_id" "Only custom scenarios can be deleted"
        exit 0
        ;;
esac

# --- Delete the scenario file ------------------------------------------------
SCENARIO_FILE="$SCENARIOS_DIR/${SCENARIO_ID}.json"

if [ ! -f "$SCENARIO_FILE" ]; then
    cgi_error "not_found" "Scenario not found"
    exit 0
fi

rm -f "$SCENARIO_FILE"

# --- If deleted scenario was active, reset to balanced ------------------------
if [ -f "$ACTIVE_SCENARIO_FILE" ]; then
    ACTIVE_ID=$(cat "$ACTIVE_SCENARIO_FILE" 2>/dev/null | tr -d ' \n\r')
    if [ "$ACTIVE_ID" = "$SCENARIO_ID" ]; then
        printf 'balanced' > "${ACTIVE_SCENARIO_FILE}.tmp" && mv "${ACTIVE_SCENARIO_FILE}.tmp" "$ACTIVE_SCENARIO_FILE"
    fi
fi

jq -n --arg id "$SCENARIO_ID" '{"success":true,"id":$id}'
