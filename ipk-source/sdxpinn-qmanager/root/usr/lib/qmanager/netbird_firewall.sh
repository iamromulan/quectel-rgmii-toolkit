#!/bin/sh
# =============================================================================
# netbird_firewall.sh — NetBird Firewall & Routing Management
# =============================================================================
# Sourced by netbird.sh CGI and the boot-time self-heal init script
# (qmanager_netbird_zone) to:
#   1. Create/remove the fw4 firewall zone for the NetBird interface (UCI-
#      persistent)
#   2. Add/remove the NetBird CGNAT range to mwan3's connected-routes ipset
#      (ephemeral — must be re-applied on every install AND every boot)
#
# Why both pieces are required:
#   - fw4's default input policy is DROP, and its input chain only jumps on
#     specific iifname matches. Without an explicit zone for wt0, inbound
#     packets on the NetBird interface fall through to the policy and are
#     silently dropped.
#   - mwan3 marks outbound traffic for WAN egress unless its source/dest is
#     in mwan3_connected_ipv4. mwan3 only auto-scans connected routes at
#     startup, and wt0 is not a UCI-managed netifd interface, so mwan3 does
#     NOT pick it up via hotplug when the daemon comes up later. Without the
#     exception, modem reply packets to 100.x peers get marked for WAN egress
#     and never make it back through the tunnel.
#
# Tailscale used to share this library, but the patched RM551E firmware
# (sdxpinn-patch) handles tailscale0 routing/firewall on its own, so this
# library is now NetBird-only.
#
# Persistence:
#   The zone lives in UCI (/etc/config/firewall) and survives reboot. The
#   mwan3 ipset entry is in-kernel only and is cleared on every reboot, so
#   the boot self-heal must re-add it. The ensure functions are idempotent.
#
# Usage:
#   . /usr/lib/qmanager/netbird_firewall.sh
#   netbird_fw_ensure_zone "netbird" "wt0"
#   netbird_fw_remove_zone "netbird"
#   netbird_fw_zone_exists "netbird"   # exit 0 if exists, 1 otherwise
# =============================================================================

[ -n "$_NETBIRD_FW_LOADED" ] && return 0
_NETBIRD_FW_LOADED=1

# Source logging if available
if [ -f /usr/lib/qmanager/qlog.sh ]; then
    . /usr/lib/qmanager/qlog.sh
else
    qlog_info()  { :; }
    qlog_error() { :; }
fi

# NetBird CGNAT range (RFC 6598).
NETBIRD_CGNAT_RANGE="100.64.0.0/10"

# -----------------------------------------------------------------------------
# netbird_fw_zone_exists <zone_name>
#   Returns 0 if a firewall zone with the given name exists, 1 otherwise.
# -----------------------------------------------------------------------------
netbird_fw_zone_exists() {
    local name="$1" i=0 val
    while true; do
        val=$(uci -q get "firewall.@zone[$i].name") || break
        [ "$val" = "$name" ] && return 0
        i=$((i + 1))
    done
    return 1
}

# -----------------------------------------------------------------------------
# netbird_fw_ensure_mwan3_exception
#   Adds NETBIRD_CGNAT_RANGE to mwan3_connected_ipv4 so mwan3 skips marking
#   NetBird-bound traffic. Idempotent. Ephemeral — must be called on every
#   install AND on every boot.
# -----------------------------------------------------------------------------
netbird_fw_ensure_mwan3_exception() {
    if ! command -v ipset >/dev/null 2>&1; then
        qlog_info "ipset not available, skipping mwan3 exception"
        return 0
    fi

    if ! ipset list mwan3_connected_ipv4 >/dev/null 2>&1; then
        qlog_info "mwan3_connected_ipv4 ipset not found, skipping"
        return 0
    fi

    if ipset test mwan3_connected_ipv4 "$NETBIRD_CGNAT_RANGE" 2>/dev/null; then
        qlog_info "mwan3 exception for $NETBIRD_CGNAT_RANGE already present"
        return 0
    fi

    ipset add mwan3_connected_ipv4 "$NETBIRD_CGNAT_RANGE" 2>/dev/null
    qlog_info "Added $NETBIRD_CGNAT_RANGE to mwan3_connected_ipv4 ipset"
    return 0
}

# -----------------------------------------------------------------------------
# netbird_fw_remove_mwan3_exception
#   Removes the CGNAT range from the mwan3 ipset. Tailscale no longer
#   consumes this range (sdxpinn-patch handles tailscale0 directly), so the
#   removal is unconditional — there is no other VPN to coordinate with.
# -----------------------------------------------------------------------------
netbird_fw_remove_mwan3_exception() {
    if ! command -v ipset >/dev/null 2>&1; then
        return 0
    fi

    if ! ipset list mwan3_connected_ipv4 >/dev/null 2>&1; then
        return 0
    fi

    ipset del mwan3_connected_ipv4 "$NETBIRD_CGNAT_RANGE" 2>/dev/null
    qlog_info "Removed $NETBIRD_CGNAT_RANGE from mwan3_connected_ipv4 ipset"
    return 0
}

# -----------------------------------------------------------------------------
# netbird_fw_ensure_zone <zone_name> <device>
#   Idempotent: creates firewall zone + forwarding rules if they don't exist.
#   Always re-asserts the mwan3 exception (ephemeral, lost on reboot).
#   Zone: input=ACCEPT, output=ACCEPT, forward=ACCEPT, device=<device>
#   Forwarding: <zone>→lan and lan→<zone>
# -----------------------------------------------------------------------------
netbird_fw_ensure_zone() {
    local zone_name="$1" device="$2"

    if [ -z "$zone_name" ] || [ -z "$device" ]; then
        qlog_error "netbird_fw_ensure_zone: missing zone_name or device"
        return 1
    fi

    # Zone already exists — still ensure mwan3 exception (ephemeral, lost on reboot)
    if netbird_fw_zone_exists "$zone_name"; then
        qlog_info "Firewall zone '$zone_name' already exists, skipping zone creation"
        netbird_fw_ensure_mwan3_exception
        return 0
    fi

    qlog_info "Creating firewall zone '$zone_name' for device '$device'"

    # Create zone
    uci add firewall zone >/dev/null
    uci set "firewall.@zone[-1].name=$zone_name"
    uci set "firewall.@zone[-1].input=ACCEPT"
    uci set "firewall.@zone[-1].output=ACCEPT"
    uci set "firewall.@zone[-1].forward=ACCEPT"
    uci set "firewall.@zone[-1].device=$device"

    # Forwarding: netbird → lan
    uci add firewall forwarding >/dev/null
    uci set "firewall.@forwarding[-1].src=$zone_name"
    uci set "firewall.@forwarding[-1].dest=lan"

    # Forwarding: lan → netbird
    uci add firewall forwarding >/dev/null
    uci set "firewall.@forwarding[-1].src=lan"
    uci set "firewall.@forwarding[-1].dest=$zone_name"

    uci commit firewall
    /etc/init.d/firewall restart >/dev/null 2>&1

    netbird_fw_ensure_mwan3_exception

    qlog_info "Firewall zone '$zone_name' created successfully"
    return 0
}

# -----------------------------------------------------------------------------
# netbird_fw_remove_zone <zone_name>
#   Removes the firewall zone and all associated forwarding rules.
#   Deletes forwarding indices in reverse order to avoid index shifting.
#   Removes the mwan3 ipset exception unconditionally.
# -----------------------------------------------------------------------------
netbird_fw_remove_zone() {
    local zone_name="$1"

    if [ -z "$zone_name" ]; then
        qlog_error "netbird_fw_remove_zone: missing zone_name"
        return 1
    fi

    if ! netbird_fw_zone_exists "$zone_name"; then
        qlog_info "Firewall zone '$zone_name' does not exist, skipping removal"
        return 0
    fi

    qlog_info "Removing firewall zone '$zone_name'"

    # --- Remove forwarding rules (reverse order) ---
    # Build fwd_indices high-to-low via the prepend form so the deletion
    # loop tears tail-first; UCI renumbers entries in place after each
    # delete, and deleting low-to-high would shift our remaining targets.
    # Only break on src lookup failure (end-of-list). A missing dest is
    # treated as a non-match so manual or partial UCI edits don't truncate
    # the scan early.
    local fwd_indices="" i=0 src dest
    while true; do
        src=$(uci -q get "firewall.@forwarding[$i].src") || break
        dest=$(uci -q get "firewall.@forwarding[$i].dest" 2>/dev/null || echo "")
        if [ "$src" = "$zone_name" ] || [ "$dest" = "$zone_name" ]; then
            fwd_indices="$i $fwd_indices"
        fi
        i=$((i + 1))
    done

    for idx in $fwd_indices; do
        uci delete "firewall.@forwarding[$idx]" 2>/dev/null
    done

    # --- Remove zone ---
    i=0
    local val
    while true; do
        val=$(uci -q get "firewall.@zone[$i].name") || break
        if [ "$val" = "$zone_name" ]; then
            uci delete "firewall.@zone[$i]" 2>/dev/null
            break
        fi
        i=$((i + 1))
    done

    uci commit firewall
    /etc/init.d/firewall restart >/dev/null 2>&1

    netbird_fw_remove_mwan3_exception

    qlog_info "Firewall zone '$zone_name' removed successfully"
    return 0
}
