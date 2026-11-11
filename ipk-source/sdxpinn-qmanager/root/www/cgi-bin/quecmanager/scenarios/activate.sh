#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# activate.sh — CGI Endpoint: Activate Connection Scenario
# =============================================================================
# Applies a connection scenario's network mode and band locks to the modem.
# Synchronous — typically 1-4 AT commands (~200ms each), returns result.
# Non-reboot (mode_pref + band locks only).
#
# DISK is the single source of truth for scenario config (D1): default
# scenarios (balanced/gaming/streaming) send mode only; custom-* scenarios are
# resolved from /etc/qmanager/scenarios/<id>.json by scenario_resolve_config.
# The POST body only needs {"id":"..."} — band data is no longer threaded
# through this endpoint.
#
# GUARD: manual activation is rejected while the active SIM profile has its
# scenario schedule enabled — the schedule owns the scenario in that case.
#
# Endpoint: POST /cgi-bin/quecmanager/scenarios/activate.sh
# Install location: /www/cgi-bin/quecmanager/scenarios/activate.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_scenario_activate"
cgi_headers
cgi_handle_options

# --- Load libraries ----------------------------------------------------------
if [ -f /usr/lib/qmanager/scenario_mgr.sh ]; then
    . /usr/lib/qmanager/scenario_mgr.sh
else
    cgi_error "internal_error" "scenario library unavailable"
    exit 0
fi
if [ -f /usr/lib/qmanager/profile_mgr.sh ]; then
    . /usr/lib/qmanager/profile_mgr.sh
else
    cgi_error "internal_error" "profile library unavailable"
    exit 0
fi

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Read POST body ----------------------------------------------------------
cgi_read_post

# --- Parse JSON fields from POST body ----------------------------------------
SCENARIO_ID=$(printf '%s' "$POST_DATA" | jq -r '(.id) | if . == null then empty else tostring end')

if [ -z "$SCENARIO_ID" ]; then
    cgi_error "no_id" "Missing id field in request body"
    exit 0
fi

# --- Validate scenario id (known default or existing custom file) ------------
if ! scenario_is_known "$SCENARIO_ID"; then
    cgi_error "invalid_id" "Unknown scenario ID"
    exit 0
fi

# --- GUARD: block manual activation while a scheduled profile is active ------
_active_profile=$(get_active_profile)
if [ -n "$_active_profile" ] && \
   [ "$(scenario_profile_schedule_enabled "$_active_profile")" = "true" ]; then
    cgi_error "scenario_locked_by_schedule" "Connection scenario is controlled by the active profile's schedule"
    exit 0
fi

# --- Apply scenario (resolves config from disk) ------------------------------
scenario_apply "$SCENARIO_ID"
_apply_rc=$?

# --- Response -----------------------------------------------------------------
case "$_apply_rc" in
    0)
        qlog_info "Scenario activated: $SCENARIO_ID"
        jq -n --arg id "$SCENARIO_ID" '{"success":true,"id":$id}'
        ;;
    2)
        qlog_warn "Scenario activated with partial band lock failure: $SCENARIO_ID"
        jq -n --arg id "$SCENARIO_ID" --arg detail "One or more band locks failed" \
            '{"success":true,"id":$id,"warning":"partial_band_lock","detail":$detail}'
        ;;
    *)
        cgi_error "modem_error" "Failed to set network mode"
        ;;
esac
