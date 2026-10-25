#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# get.sh — CGI Endpoint: Get Single SIM Profile
# =============================================================================
# Returns the full profile JSON for a given profile ID.
# No modem interaction — reads from flash only.
#
# Endpoint: GET /cgi-bin/quecmanager/profiles/get.sh?id=<profile_id>
# Response: Full profile JSON or {"success":false,"error":"..."}
#
# Install location: /www/cgi-bin/quecmanager/profiles/get.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_profile_get"
cgi_headers
cgi_handle_options

# --- Source profile manager library ------------------------------------------
. /usr/lib/qmanager/profile_mgr.sh

# --- Extract profile ID from query string ------------------------------------
# QUERY_STRING format: id=p_1707900000_abc
PROFILE_ID=$(echo "$QUERY_STRING" | sed -n 's/.*id=\([^&]*\).*/\1/p')

if [ -z "$PROFILE_ID" ]; then
    cgi_error "no_id" "Missing id parameter"
    exit 0
fi

# --- Sanitize ID (prevent path traversal) ------------------------------------
# Profile IDs must match: p_<digits>_<hex>
case "$PROFILE_ID" in
    p_[0-9]*_[0-9a-f]*)
        # Valid format — continue
        ;;
    *)
        cgi_error "invalid_id" "Invalid profile ID format"
        exit 0
        ;;
esac

# --- Serve profile -----------------------------------------------------------
if ! profile_get "$PROFILE_ID"; then
    cgi_error "not_found" "Profile not found"
fi
