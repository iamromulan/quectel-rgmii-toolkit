#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# ipa_offload.sh — CGI Endpoint: IPA / r8125 IOSS Offload Toggle (GET + POST)
# =============================================================================
# Manages ONLY the boot-time enable state of the r8125_ioss.init service via
# its own enable/disable subcommands. The change takes effect on the NEXT boot
# — this endpoint NEVER starts/stops the service at runtime, NEVER loads or
# unloads kernel modules, and NEVER reboots. The frontend surfaces a
# pending-reboot banner instead (no-in-flight-reboot rule).
#
# Auth: enforced at source time by cgi_base.sh (require_auth).
#
# GET  → {"success":true,"available":<bool>,"enabled":<bool>}
#          available=false when the init script is absent (enabled then false).
# POST {"action":"enable"|"disable"} →
#          {"success":true,"enabled":<bool>,"pending_reboot_required":true}
# Errors: not_available | invalid_action | method_not_allowed
#
# Endpoint: GET/POST /cgi-bin/quecmanager/system/ipa_offload.sh
# Install location: /www/cgi-bin/quecmanager/system/ipa_offload.sh
# =============================================================================

qlog_init "cgi_ipa_offload"
cgi_headers
cgi_handle_options

INIT="/etc/init.d/r8125_ioss.init"

# Is the init script present (offload feature available on this build)?
is_available() {
    [ -f "$INIT" ]
}

# Boot-enabled state. `<init> enabled` exits 0 when enabled at boot, non-zero
# otherwise. Returns the literal "true"/"false" string on stdout.
read_enabled() {
    if [ -x "$INIT" ] && "$INIT" enabled >/dev/null 2>&1; then
        echo "true"
    else
        echo "false"
    fi
}

# =============================================================================
# GET — Report availability + current boot-enable state
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    if is_available; then
        ENABLED=$(read_enabled)
        jq -n --argjson enabled "$ENABLED" \
            '{success:true, available:true, enabled:$enabled}'
    else
        jq -n '{success:true, available:false, enabled:false}'
    fi
    exit 0
fi

# =============================================================================
# POST — Toggle boot-enable state
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    if ! is_available; then
        qlog_warn "IPA offload toggle requested but init script absent: $INIT"
        cgi_error "not_available" "IPA offload service is not installed on this device"
        exit 0
    fi

    ACTION=$(printf '%s' "$POST_DATA" | jq -r 'if .action == null then empty else .action end')

    case "$ACTION" in
        enable)
            qlog_info "Enabling IPA offload at boot"
            "$INIT" enable >/dev/null 2>&1
            ;;
        disable)
            qlog_info "Disabling IPA offload at boot"
            "$INIT" disable >/dev/null 2>&1
            ;;
        *)
            cgi_error "invalid_action" "action must be 'enable' or 'disable'"
            exit 0
            ;;
    esac

    ENABLED=$(read_enabled)
    qlog_info "IPA offload boot-enable now: $ENABLED (reboot pending)"

    jq -n --argjson enabled "$ENABLED" \
        '{success:true, enabled:$enabled, pending_reboot_required:true}'
    exit 0
fi

# Method not allowed
cgi_error "method_not_allowed" "Only GET and POST are supported"
