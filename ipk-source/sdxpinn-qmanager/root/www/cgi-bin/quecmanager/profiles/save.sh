#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# save.sh — CGI Endpoint: Create or Update SIM Profile
# =============================================================================
# Accepts a JSON profile definition via POST body. If the JSON contains an
# "id" field matching an existing profile, it updates. Otherwise, it creates.
#
# Enforces the 10-profile limit on create.
#
# Saving the ACTIVE profile with a changed scenario binding re-arms its
# schedule cron (scenario_install_cron: cron lines + snap-to-now scenario,
# AT mode/band only; no CFUN, no APN cycle, no MPDN, no reboot). Network
# fields still wait for the next activation. Skipped while a profile apply
# runs: the worker installs cron from disk when it finalizes.
#
# Endpoint: POST /cgi-bin/quecmanager/profiles/save.sh
# Request body: Profile JSON (see architecture doc §4.1)
# Response: {"success":true,"id":"<profile_id>"}
#       or: {"success":false,"error":"...","detail":"..."}
#
# Install location: /www/cgi-bin/quecmanager/profiles/save.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_profile_save"
cgi_headers
cgi_handle_options

# --- Source libraries --------------------------------------------------------
if [ -f /usr/lib/qmanager/profile_mgr.sh ]; then
    . /usr/lib/qmanager/profile_mgr.sh
else
    cgi_error "internal_error" "profile library unavailable"
    exit 0
fi
_have_scenario_mgr=0
if [ -f /usr/lib/qmanager/scenario_mgr.sh ]; then
    . /usr/lib/qmanager/scenario_mgr.sh
    _have_scenario_mgr=1
fi

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Read POST body ----------------------------------------------------------
cgi_read_post

qlog_info "Profile save request received (${CONTENT_LENGTH} bytes)"

# --- Capture the active profile's binding before the write -------------------
# Only the active id (read from our own marker file) is ever used as a path.
_req_id=$(printf '%s' "$POST_DATA" | jq -r '.id // empty' 2>/dev/null)
_active_id=$(get_active_profile)
_was_active=0
_old_block=""
if [ "$_have_scenario_mgr" = "1" ] && [ -n "$_req_id" ] && [ "$_req_id" = "$_active_id" ]; then
    _was_active=1
    _old_block=$(scenario_profile_block "$_active_id")
fi

# --- Pass to profile_save (reads from stdin) ---------------------------------
_result=$(printf '%s' "$POST_DATA" | profile_save)
if [ -z "$_result" ]; then
    cgi_error "internal_error" "Profile save produced no result"
    exit 0
fi
_ok=$(printf '%s' "$_result" | jq -r '.success // false' 2>/dev/null)

if [ "$_ok" != "true" ] || [ "$_was_active" != "1" ]; then
    printf '%s\n' "$_result"
    exit 0
fi

# --- Active profile saved: re-arm its schedule if the binding changed --------
_new_block=$(scenario_profile_block "$_active_id")
_rearmed="false"
if [ "$_new_block" != "$_old_block" ]; then
    if profile_check_lock; then
        scenario_install_cron "$_active_id" >/dev/null 2>&1
        _rearmed="true"
        qlog_info "Active profile $_active_id binding changed; schedule re-armed"
    else
        qlog_info "Active profile $_active_id binding changed during apply; worker will install"
    fi
fi

printf '%s' "$_result" | jq -c --argjson r "$_rearmed" '. + {schedule_rearmed: $r}'
