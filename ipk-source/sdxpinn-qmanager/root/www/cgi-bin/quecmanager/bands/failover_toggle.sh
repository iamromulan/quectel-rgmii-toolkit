#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh
# =============================================================================
# failover_toggle.sh — CGI Endpoint: Toggle Band Failover
# =============================================================================
# Enables or disables the band failover safety mechanism. When enabled,
# a one-shot watcher is spawned after each band lock operation that reverts
# to all supported bands if the modem loses service within 15 seconds.
#
# The setting persists on flash (/etc/qmanager/band_failover_enabled).
#
# POST body:
#   {"enabled": true}   — enable failover
#   {"enabled": false}  — disable failover
#
# Endpoint: POST /cgi-bin/quecmanager/bands/failover_toggle.sh
# Install location: /www/cgi-bin/quecmanager/bands/failover_toggle.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_bands_failover"
cgi_headers
cgi_handle_options

# --- Configuration -----------------------------------------------------------
FAILOVER_ENABLED_FILE="/etc/qmanager/band_failover_enabled"
FAILOVER_ACTIVATED_FLAG="/tmp/qmanager_band_failover"
FAILOVER_PID_FILE="/tmp/qmanager_band_failover.pid"

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Read POST body ----------------------------------------------------------
cgi_read_post

# --- Parse enabled value -----------------------------------------------------
# Handle both "enabled":true and "enabled":"true" formats
ENABLED_VAL=$(printf '%s' "$POST_DATA" | jq -r 'if has("enabled") then (.enabled | tostring) else empty end')

if [ -z "$ENABLED_VAL" ]; then
    cgi_error "no_enabled" "Missing or invalid enabled field (expected true or false)"
    exit 0
fi

# --- Persist setting ---------------------------------------------------------
mkdir -p "$(dirname "$FAILOVER_ENABLED_FILE")" 2>/dev/null

if [ "$ENABLED_VAL" = "true" ]; then
    if ! printf '1' | qm_durable_write "$FAILOVER_ENABLED_FILE"; then
        cgi_error "write_failed" "Could not save the setting"
        exit 0
    fi
    qlog_info "Band failover ENABLED"
    jq -n '{"success":true,"enabled":true}'
else
    if ! printf '0' | qm_durable_write "$FAILOVER_ENABLED_FILE"; then
        cgi_error "write_failed" "Could not save the setting"
        exit 0
    fi
    qlog_info "Band failover DISABLED"

    # Kill any running watcher to prevent unexpected failovers
    if [ -f "$FAILOVER_PID_FILE" ]; then
        # B4.1: kill only a root-owned pidfile whose pid is the failover daemon
        old_pid=$(qm_read_pid "$FAILOVER_PID_FILE" qmanager_band_failover)
        if [ -n "$old_pid" ]; then
            kill -9 "$old_pid" 2>/dev/null
            qlog_warn "Killed active failover watcher (PID=$old_pid) due to toggle OFF"
        fi
        rm -f "$FAILOVER_PID_FILE"
    fi

    # Clear any active failover flag so the UI resets from "Using Default Bands"
    rm -f "$FAILOVER_ACTIVATED_FLAG"

    jq -n '{"success":true,"enabled":false}'
fi
