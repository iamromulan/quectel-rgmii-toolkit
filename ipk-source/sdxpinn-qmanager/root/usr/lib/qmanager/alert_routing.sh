#!/bin/sh
# =============================================================================
# alert_routing.sh — Alert Routing + Capability Library for QManager
# =============================================================================
# Single source of truth for the trigger x channel routing matrix AND the
# hard-coded capability table. Sourced by qmanager_poller (via the alert
# engine) and by the monitoring/alerts.sh CGI.
#
# Model:
#   Events   : connection_lost, connection_restored
#   Channels : sms, email
#   Routing  : user preference (persisted in alert_routing.json)
#   Capability : a physical fact the backend is authoritative over. email needs
#                internet + DNS, both of which are down during an outage, so
#                connection_lost/email is INCAPABLE and can never be routed.
#
# Effective send rule (checked by the engine): send (event, channel) iff
#   channel master-enabled  AND  routing cell true  AND  capable.
# This library owns the routing + capability halves; master-enable lives with
# the channel libs.
#
# Config: /etc/qmanager/alert_routing.json  (additive; never mutates the
#         sms_alerts.json / email_alerts.json shapes)
# Reload: /tmp/qmanager_alert_routing_reload
# =============================================================================

[ -n "$_ALERT_ROUTING_LOADED" ] && return 0
_ALERT_ROUTING_LOADED=1

_AR_CONFIG="/etc/qmanager/alert_routing.json"
_AR_RELOAD_FLAG="/tmp/qmanager_alert_routing_reload"

# --- Cached routing cells ("true"/"false"). Defaults reproduce the pre-
# --- centralization behavior exactly: SMS on for both events, email on for
# --- recovery only, email off (and incapable) for the outage-start event.
_ar_cl_sms="true"
_ar_cl_email="false"
_ar_cr_sms="true"
_ar_cr_email="true"
# reboot is OPT-IN: default OFF on both channels. Detection + the reboot ledger
# still record every boot regardless — only delivery is gated by these cells.
_ar_rb_sms="false"
_ar_rb_email="false"

# =============================================================================
# alert_default_routing_json — canonical default routing document
# =============================================================================
# Used by the installer seed and as the fail-closed in-memory fallback. The
# shape is versioned so a future migration can detect old documents. version 2
# adds the additive "reboot" event (default off/off).
alert_default_routing_json() {
    printf '%s' '{"version":2,"events":{"connection_lost":{"sms":true,"email":false},"connection_restored":{"sms":true,"email":true},"reboot":{"sms":false,"email":false}}}'
}

# =============================================================================
# alert_routing_load — read config into cached cells (fail-closed to defaults)
# =============================================================================
# Always re-reads the file; missing file or bad JSON leaves the defaults in
# place (fail-closed == current behavior). Consumes the reload flag if present.
# Booleans are parsed with the null-safe "if . == null" form, never `//`, so a
# genuine `false` in the file is preserved rather than silently defaulted.
alert_routing_load() {
    # Reset to defaults first so a partial/absent file yields a known state.
    _ar_cl_sms="true"
    _ar_cl_email="false"
    _ar_cr_sms="true"
    _ar_cr_email="true"
    # reboot defaults OFF/OFF — a v1 file (no "reboot" key) therefore fail-closes
    # to opt-in, which is exactly the desired default. No migration needed.
    _ar_rb_sms="false"
    _ar_rb_email="false"

    if [ -f "$_AR_CONFIG" ] && jq -e '.events' "$_AR_CONFIG" >/dev/null 2>&1; then
        _ar_cl_sms=$(jq -r '(.events.connection_lost.sms)         | if . == null then "true"  else tostring end' "$_AR_CONFIG" 2>/dev/null)
        _ar_cl_email=$(jq -r '(.events.connection_lost.email)     | if . == null then "false" else tostring end' "$_AR_CONFIG" 2>/dev/null)
        _ar_cr_sms=$(jq -r '(.events.connection_restored.sms)     | if . == null then "true"  else tostring end' "$_AR_CONFIG" 2>/dev/null)
        _ar_cr_email=$(jq -r '(.events.connection_restored.email) | if . == null then "true"  else tostring end' "$_AR_CONFIG" 2>/dev/null)
        _ar_rb_sms=$(jq -r '(.events.reboot.sms)                  | if . == null then "false" else tostring end' "$_AR_CONFIG" 2>/dev/null)
        _ar_rb_email=$(jq -r '(.events.reboot.email)              | if . == null then "false" else tostring end' "$_AR_CONFIG" 2>/dev/null)
    fi

    # Coerce anything that isn't exactly "true" to "false" (fail-closed).
    [ "$_ar_cl_sms" = "true" ]   || _ar_cl_sms="false"
    [ "$_ar_cr_sms" = "true" ]   || _ar_cr_sms="false"
    [ "$_ar_cr_email" = "true" ] || _ar_cr_email="false"
    [ "$_ar_rb_sms" = "true" ]   || _ar_rb_sms="false"
    [ "$_ar_rb_email" = "true" ] || _ar_rb_email="false"

    # Capability clamp: connection_lost/email can never be routed on, no matter
    # what the file says — email is physically incapable during an outage. NO
    # clamp for reboot: it is delivered post-recovery when both channels work.
    _ar_cl_email="false"

    [ -f "$_AR_RELOAD_FLAG" ] && rm -f "$_AR_RELOAD_FLAG"
}

# =============================================================================
# alert_capable <event> <channel> — hard-coded capability table
# =============================================================================
# Returns 0 if the channel can physically deliver for the event, 1 otherwise.
# The ONLY incapable pair is connection_lost/email.
alert_capable() {
    case "$1/$2" in
        connection_lost/sms)       return 0 ;;
        connection_lost/email)     return 1 ;;
        connection_restored/sms)   return 0 ;;
        connection_restored/email) return 0 ;;
        reboot/sms)                return 0 ;;
        reboot/email)              return 0 ;;
        *)                         return 1 ;;
    esac
}

# =============================================================================
# alert_route_enabled <event> <channel> — routing AND capability gate
# =============================================================================
# Returns 0 iff the routing cell is "true" AND the pair is capable. Master-
# enable (per-channel config.enabled) is checked separately by the engine.
alert_route_enabled() {
    alert_capable "$1" "$2" || return 1
    case "$1/$2" in
        connection_lost/sms)       [ "$_ar_cl_sms" = "true" ] ;;
        connection_lost/email)     [ "$_ar_cl_email" = "true" ] ;;
        connection_restored/sms)   [ "$_ar_cr_sms" = "true" ] ;;
        connection_restored/email) [ "$_ar_cr_email" = "true" ] ;;
        reboot/sms)                [ "$_ar_rb_sms" = "true" ] ;;
        reboot/email)              [ "$_ar_rb_email" = "true" ] ;;
        *)                         return 1 ;;
    esac
}

# =============================================================================
# alert_capabilities_json — capability matrix for the CGI GET
# =============================================================================
# The frontend renders channel availability from THIS, never from a hard-coded
# client table. email_reason is a stable key the UI maps to a message.
alert_capabilities_json() {
    printf '%s' '{"connection_lost":{"sms":true,"email":false,"email_reason":"email_needs_internet"},"connection_restored":{"sms":true,"email":true},"reboot":{"sms":true,"email":true}}'
}
