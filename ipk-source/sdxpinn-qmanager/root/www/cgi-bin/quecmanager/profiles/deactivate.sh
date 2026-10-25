#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# deactivate.sh — CGI Endpoint: Deactivate (Clear) Active SIM Profile
# =============================================================================
# Clears the active profile marker so no profile is shown as active.
# Modem settings are NOT reverted — they persist in modem NVM. This only
# removes the "active" designation from the UI.
#
# Endpoint: POST /cgi-bin/quecmanager/profiles/deactivate.sh
# Request body: (none required)
# Response: {"success":true}
#       or: {"success":false,"error":"...","detail":"..."}
#
# Install location: /www/cgi-bin/quecmanager/profiles/deactivate.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_profile_deactivate"
cgi_headers
cgi_handle_options

# --- Source profile manager library ------------------------------------------
. /usr/lib/qmanager/profile_mgr.sh

# --- AT helper + APN manager (for reapplying the active APN slot) ------------
# cgi_at.sh defines run_at and must precede apn_mgr.sh; apn_mgr.sh also sources
# cgi_at.sh itself (load-guarded), so order is belt-and-suspenders here.
. /usr/lib/qmanager/cgi_at.sh
. /usr/lib/qmanager/apn_mgr.sh

# --- Events (for append_event) -----------------------------------------------
EVENTS_FILE="/tmp/qmanager_events.json"
MAX_EVENTS=50
if [ -f /usr/lib/qmanager/events.sh ]; then
    . /usr/lib/qmanager/events.sh
else
    append_event() { :; }
fi

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

qlog_info "Profile deactivate request"

# --- Look up profile name before clearing ------------------------------------
_deact_id=$(get_active_profile)
_deact_name=""
if [ -n "$_deact_id" ] && [ -f "$PROFILE_DIR/${_deact_id}.json" ]; then
    _deact_name=$(jq -r '(.name) | if . == null then empty else tostring end' "$PROFILE_DIR/${_deact_id}.json" 2>/dev/null)
fi

# --- Verizon MPDN revert (before clearing marker) ----------------------------
_deact_mno=""
if [ -n "$_deact_id" ] && [ -f "$PROFILE_DIR/${_deact_id}.json" ]; then
    _deact_mno=$(jq -r '(.mno) | if . == null then empty else tostring end' "$PROFILE_DIR/${_deact_id}.json" 2>/dev/null)
fi
_deact_requires_reboot="false"
if [ "$_deact_mno" = "Verizon" ]; then
    if mpdn_revert_to_default; then
        _deact_requires_reboot="true"
        append_event "verizon_mpdn_reverted" "Verizon profile '$_deact_name' deactivated — data routing reverted, reboot required" "info"
    else
        _deact_requires_reboot="true"
        append_event "verizon_mpdn_reverted" "Verizon profile '$_deact_name' deactivated — MPDN revert verification failed, reboot recommended" "warning"
    fi
fi

# --- Clear active profile ----------------------------------------------------
clear_active_profile

# --- Tear down profile-scenario schedule cron --------------------------------
# Deactivating a profile must remove any scenario cron lines it installed.
if [ -f /usr/lib/qmanager/scenario_mgr.sh ]; then
    . /usr/lib/qmanager/scenario_mgr.sh
fi
if command -v scenario_teardown_cron >/dev/null 2>&1; then
    scenario_teardown_cron
fi

# --- Reset connection scenario to Balanced (default) -------------------------
# Deactivating a profile must not leave the radio locked to the profile's
# scenario. Mode-only: returns mode_pref to AUTO and writes active_scenario.
if command -v scenario_reset_to_default >/dev/null 2>&1; then
    scenario_reset_to_default
fi

# --- Reapply APN Management's active slot to the modem -----------------------
# The deactivated Custom SIM Profile left its own APN live on the modem, while
# APN Management still badges its stored active slot as "Active" — a confirmed
# mismatch. Restore the active slot so the live APN matches the UI.
#
# Non-Verizon path ONLY. A Verizon revert already requires a reboot and leaves
# the MPDN rule mid-revert; the poller's boot APN reconcile restores the slot
# after reboot, so we must NOT fire a COPS cycle into that pending-reboot state.
#
# Best-effort: a reapply failure does NOT change the response — deactivation
# still succeeds with requires_reboot=false. Failures are surfaced as events.
if [ "$_deact_requires_reboot" = "false" ]; then
    _reapplied=$(reapply_active_apn_slot)
    _reapply_rc=$?
    if [ "$_reapply_rc" -ne 0 ]; then
        qlog_warn "APN reapply after deactivate failed: ${APN_APPLY_ERR_CODE:-unknown}"
        append_event "apn_reapply_failed" "APN profile could not be restored after deactivation" "warning"
    elif [ -n "$_reapplied" ]; then
        append_event "apn_reapplied" "APN profile restored after profile deactivation" "info"
    fi
fi

# --- Emit network event ------------------------------------------------------
if [ -n "$_deact_name" ]; then
    append_event "profile_deactivated" "Profile '$_deact_name' deactivated" "info"
fi

jq -n --argjson reboot "$_deact_requires_reboot" '{success: true, requires_reboot: $reboot}'
