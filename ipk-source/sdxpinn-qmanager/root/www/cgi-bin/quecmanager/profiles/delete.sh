#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# delete.sh — CGI Endpoint: Delete SIM Profile
# =============================================================================
# Removes a profile by ID. If the deleted profile was active, clears the
# active profile tracker. Modem settings are NOT reverted — they persist
# in modem NVM. The UI shows "No active profile" after deletion.
#
# Endpoint: POST /cgi-bin/quecmanager/profiles/delete.sh
# Request body: {"id": "<profile_id>"}
# Response: {"success":true,"id":"<profile_id>"}
#       or: {"success":false,"error":"...","detail":"..."}
#
# Install location: /www/cgi-bin/quecmanager/profiles/delete.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_profile_delete"
cgi_headers
cgi_handle_options

# --- Source profile manager library ------------------------------------------
. /usr/lib/qmanager/profile_mgr.sh

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Read POST body ----------------------------------------------------------
cgi_read_post

# --- Extract profile ID from JSON body ----------------------------------------
PROFILE_ID=$(printf '%s' "$POST_DATA" | jq -r '.id // empty')

if [ -z "$PROFILE_ID" ]; then
    cgi_error "no_id" "Missing id field in request body"
    exit 0
fi

# --- Sanitize ID (prevent path traversal) ------------------------------------
case "$PROFILE_ID" in
    p_[0-9]*_[0-9a-f]*)
        # Valid format
        ;;
    *)
        cgi_error "invalid_id" "Invalid profile ID format"
        exit 0
        ;;
esac

qlog_info "Profile delete request: $PROFILE_ID"

# --- Delete -------------------------------------------------------------------
profile_delete "$PROFILE_ID"
