#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# list.sh — CGI Endpoint: List All SIM Profiles
# =============================================================================
# Returns a JSON object containing all profile summaries and the active
# profile ID. No modem interaction — reads from flash only.
#
# Endpoint: GET /cgi-bin/quecmanager/profiles/list.sh
# Response: {"profiles":[...],"active_profile_id":"..."|null}
#
# Install location: /www/cgi-bin/quecmanager/profiles/list.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_profile_list"
cgi_headers
cgi_handle_options

# --- Source profile manager library ------------------------------------------
. /usr/lib/qmanager/profile_mgr.sh

# --- Serve profile list ------------------------------------------------------
profile_list
