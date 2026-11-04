#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# host_at_ports.sh — CGI Endpoint: host AT ports on/off (GET + POST)
# =============================================================================
# Turns the vendor port-bridged service on or off. That service relays the
# USB/PCIe host AT ports into the modem's AT engine. QManager never uses them:
# its own AT path is /dev/smd11. Turning them off stops a USB/PCIe-attached
# host from sending AT commands. It does NOT make QManager faster.
# Applies immediately and persists across reboots; never reboots.
#
# Auth: enforced at source time by cgi_base.sh (require_auth).
#
# GET  -> {"success":true,"available":<bool>,"enabled":<bool>,"running":<bool>,"pcie":<bool>}
# POST {"enabled":true|false} -> same shape as GET, after applying.
# Errors: not_available | invalid_value | apply_failed | method_not_allowed
#
# Endpoint: GET/POST /cgi-bin/quecmanager/system/host_at_ports.sh
# Install location: /www/cgi-bin/quecmanager/system/host_at_ports.sh
# =============================================================================

qlog_init "cgi_host_at_ports"
cgi_headers
cgi_handle_options

[ -f /usr/lib/qmanager/at_engine.sh ] && . /usr/lib/qmanager/at_engine.sh

bool() { "$@" && echo true || echo false; }

emit_state() {
    if ! host_at_available; then
        jq -n '{success:true, available:false, enabled:false, running:false, pcie:false}'
        return
    fi
    _en=false
    [ "$(host_at_get)" = "1" ] && _en=true
    jq -n \
        --argjson enabled "$_en" \
        --argjson running "$(bool host_at_running)" \
        --argjson pcie "$(bool host_at_pcie)" \
        '{success:true, available:true, enabled:$enabled, running:$running, pcie:$pcie}'
}

if ! command -v host_at_get >/dev/null 2>&1; then
    cgi_error "apply_failed" "AT engine library is missing"
    exit 0
fi

if [ "$REQUEST_METHOD" = "GET" ]; then
    emit_state
    exit 0
fi

if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post

    if ! host_at_available; then
        cgi_error "not_available" "Host AT ports are not present on this device"
        exit 0
    fi

    # jq without regex (device jq has no Oniguruma): booleans only.
    VALUE=$(printf '%s' "$POST_DATA" | jq -r 'if (.enabled | type) == "boolean" then (if .enabled then "1" else "0" end) else empty end')
    case "$VALUE" in
        0|1) ;;
        *)
            cgi_error "invalid_value" "enabled must be true or false"
            exit 0
            ;;
    esac

    uci -q get quecmanager.ports >/dev/null 2>&1 || uci set quecmanager.ports=ports
    uci set quecmanager.ports.host_at="$VALUE"
    if ! uci commit quecmanager; then
        cgi_error "apply_failed" "Could not save the host AT port setting"
        exit 0
    fi

    host_at_apply
    qlog_info "Host AT ports set to $VALUE (running: $(bool host_at_running))"
    emit_state
    exit 0
fi

cgi_error "method_not_allowed" "Only GET and POST are supported"
