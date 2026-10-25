#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# mtu.sh — CGI Endpoint: MTU Configuration (GET + POST)
# =============================================================================
# GET:  Reads the current MTU from the rmnet_data0 interface and checks
#       whether a custom MTU configuration file exists.
# POST: Applies a new MTU value to all rmnet_data interfaces and persists
#       the commands to /etc/firewall.user.mtu. The qmanager_mtu init script
#       re-applies these at boot via the qmanager_mtu_apply daemon.
#       Send { "mtu": "disable" } to remove custom MTU and revert to default.
#
# Files:
#   /etc/firewall.user.mtu          — Persistent MTU commands (ip link set)
#
# POST body: { "mtu": 1420 }   or   { "mtu": "disable" }
#
# Endpoint: GET/POST /cgi-bin/quecmanager/network/mtu.sh
# Install location: /www/cgi-bin/quecmanager/network/mtu.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_mtu"
cgi_headers
cgi_handle_options

# --- Configuration -----------------------------------------------------------
MTU_FIREWALL_FILE="/etc/firewall.user.mtu"
NETWORK_INTERFACE="rmnet_data0"

# --- Helper: get current MTU from the primary interface ----------------------
get_current_mtu() {
    ip link show "$NETWORK_INTERFACE" 2>/dev/null \
        | grep -o "mtu [0-9]*" | cut -d' ' -f2
}

# =============================================================================
# GET — Read current MTU status
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Reading MTU configuration"

    current_mtu=$(get_current_mtu)
    current_mtu=${current_mtu:-1500}

    is_enabled="false"
    if [ -f "$MTU_FIREWALL_FILE" ]; then
        is_enabled="true"
    fi

    qlog_info "Current MTU=$current_mtu enabled=$is_enabled"

    jq -n \
        --argjson is_enabled "$is_enabled" \
        --argjson current_value "$current_mtu" \
        '{
            success: true,
            is_enabled: $is_enabled,
            current_value: $current_value
        }'
    exit 0
fi

# =============================================================================
# POST — Apply or disable MTU configuration
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    mtu_value=$(printf '%s' "$POST_DATA" | jq -r '(.mtu) | if . == null then empty else tostring end')

    if [ -z "$mtu_value" ]; then
        cgi_error "missing_field" "mtu field is required"
        exit 0
    fi

    # --- Handle disable ---
    if [ "$mtu_value" = "disable" ]; then
        qlog_info "Disabling custom MTU"

        rm -f "$MTU_FIREWALL_FILE"

        default_mtu=$(get_current_mtu)
        default_mtu=${default_mtu:-1500}

        qlog_info "MTU disabled, current=$default_mtu"

        jq -n \
            --argjson current_value "$default_mtu" \
            '{
                success: true,
                message: "MTU configuration disabled",
                current_value: $current_value
            }'
        exit 0
    fi

    # --- Validate MTU (numeric, reasonable range) ---
    case "$mtu_value" in
        ''|*[!0-9]*)
            cgi_error "invalid_mtu" "MTU must be a number"
            exit 0
            ;;
    esac
    if [ "$mtu_value" -lt 576 ] 2>/dev/null || [ "$mtu_value" -gt 9000 ] 2>/dev/null; then
        cgi_error "invalid_mtu" "MTU must be between 576 and 9000"
        exit 0
    fi

    qlog_info "Setting MTU=$mtu_value"

    # --- Write firewall MTU configuration file (atomic: temp + mv) ---
    MTU_TMP="${MTU_FIREWALL_FILE}.tmp"
    > "$MTU_TMP"
    for iface in $(ls /sys/class/net 2>/dev/null | grep '^rmnet_data'); do
        echo "ip link set $iface mtu $mtu_value" >> "$MTU_TMP"
    done
    mv "$MTU_TMP" "$MTU_FIREWALL_FILE"

    # --- Immediately apply MTU ---
    for iface in $(ls /sys/class/net 2>/dev/null | grep '^rmnet_data'); do
        ip link set "$iface" mtu "$mtu_value" 2>/dev/null
    done

    qlog_info "MTU set to $mtu_value"

    jq -n \
        --argjson current_value "$mtu_value" \
        '{
            success: true,
            message: "MTU configuration updated",
            current_value: $current_value
        }'
    exit 0
fi

# --- Method not allowed -------------------------------------------------------
cgi_method_not_allowed
