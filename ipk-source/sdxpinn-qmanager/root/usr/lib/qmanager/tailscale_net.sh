#!/bin/sh
# =============================================================================
# tailscale_net.sh — the single owner of Tailscale reachability on the modem
# =============================================================================
# Two pieces, both required for plain IP (ping / SSH / HTTPS) over the tailnet:
#
#   1. fw4 zone for tailscale0 (UCI, persistent). fw4's input policy is DROP
#      and tailscaled's own accept rules live in another nft table, so without
#      a zone inbound tunnel traffic is dropped. A zone the firmware already
#      ships (any zone listing tailscale0) is reused and never modified.
#
#   2. ip rule `to 100.64.0.0/10 lookup 52 pref 1990` (+ the IPv6 ULA range).
#      mwan3 marks outbound traffic 0x11 and its `2005 fwmark 0x11 lookup 5`
#      rule beats tailscaled's `5270 lookup 52`, so replies to peers leak out
#      rmnet_data0. The old fix (adding 100.64.0.0/10 to mwan3_connected_ipv4)
#      does not last: mwan3 flushes and rebuilds that ipset on every refresh.
#      mwan3 never touches pref 1990, and the rule only reorders what table 52
#      already routes. Kernel-only, so it is re-asserted at boot, on connect
#      and on daemon start.
#
# Never runs `firewall reload` inside an HTTP response: callers that may be
# serving a request use ts_net_ensure_zone / `--no-reload` and reload in the
# background afterwards.
#
# Ownership: none of this applies to the Tiny build (iamromulan tailscale-tiny
# opkg package). Its own init script creates the fw4 zone and moves tailscaled's
# ip rules ahead of mwan3, so every caller checks ts_net_owned first.
# =============================================================================

[ -n "$_TS_NET_LOADED" ] && return 0
_TS_NET_LOADED=1

TS_NET_ZONE="tailscale"
TS_NET_DEV="tailscale0"
TS_NET_PREF="1990"
TS_NET_TABLE="52"
TS_NET_V4="100.64.0.0/10"
TS_NET_V6="fd7a:115c:a1e0::/48"

_ts_net_log() {
    if command -v qlog_info >/dev/null 2>&1; then
        qlog_info "tailscale_net: $1"
    fi
}

# rc 0 unless quecmanager.tailscale_net.enabled is explicitly 0 (default ON).
ts_net_enabled() {
    [ "$(uci -q get quecmanager.tailscale_net.enabled 2>/dev/null)" != "0" ]
}

# rc 0 when the installed Tailscale is the Tiny opkg build. The install marker
# is authoritative; the opkg info file covers installs that predate it.
ts_net_tiny_installed() {
    local marker
    marker=$(tr -d ' \n\r' < /etc/tailscale/.qm_install_method 2>/dev/null)
    case "$marker" in
        tiny) return 0 ;;
        official) return 1 ;;
    esac
    [ -f /usr/lib/opkg/info/tailscale-tiny.control ]
}

# rc 0 when QManager owns reachability (anything but the Tiny build).
ts_net_owned() {
    ! ts_net_tiny_installed
}

# Index of the zone named $TS_NET_ZONE, or nothing.
_ts_net_own_zone_idx() {
    local i
    local name
    i=0
    while name=$(uci -q get "firewall.@zone[$i].name"); do
        if [ "$name" = "$TS_NET_ZONE" ]; then
            printf '%s' "$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# rc 0 if a zone is named tailscale, or any zone's device/network lists tailscale0.
ts_net_zone_present() {
    local i
    local name
    local dev
    local net
    i=0
    while name=$(uci -q get "firewall.@zone[$i].name"); do
        [ "$name" = "$TS_NET_ZONE" ] && return 0
        dev=$(uci -q get "firewall.@zone[$i].device")
        net=$(uci -q get "firewall.@zone[$i].network")
        case " $dev $net " in
            *" $TS_NET_DEV "*) return 0 ;;
        esac
        i=$((i + 1))
    done
    return 1
}

# rc 0 if a forwarding src=$1 dest=$2 exists.
_ts_net_fwd_present() {
    local i
    local src
    local dest
    i=0
    while src=$(uci -q get "firewall.@forwarding[$i].src"); do
        dest=$(uci -q get "firewall.@forwarding[$i].dest")
        [ "$src" = "$1" ] && [ "$dest" = "$2" ] && return 0
        i=$((i + 1))
    done
    return 1
}

_ts_net_fwd_add() {
    uci add firewall forwarding >/dev/null || return 1
    uci set "firewall.@forwarding[-1].src=$1"
    uci set "firewall.@forwarding[-1].dest=$2"
}

# UCI only, commits, never reloads. rc 0 = changed, 1 = no change (or failure).
# A foreign zone that already lists tailscale0 is left exactly as it is.
ts_net_ensure_zone() {
    local changed
    changed=0
    if ! ts_net_zone_present; then
        uci add firewall zone >/dev/null || return 1
        uci set "firewall.@zone[-1].name=$TS_NET_ZONE"
        uci set "firewall.@zone[-1].input=ACCEPT"
        uci set "firewall.@zone[-1].output=ACCEPT"
        uci set "firewall.@zone[-1].forward=ACCEPT"
        uci set "firewall.@zone[-1].device=$TS_NET_DEV"
        changed=1
        _ts_net_log "created fw4 zone $TS_NET_ZONE ($TS_NET_DEV)"
    fi
    # Forwardings only for our own zone (a firmware zone keeps its policy).
    if _ts_net_own_zone_idx >/dev/null; then
        if ! _ts_net_fwd_present "$TS_NET_ZONE" lan; then
            _ts_net_fwd_add "$TS_NET_ZONE" lan && changed=1
        fi
        if ! _ts_net_fwd_present lan "$TS_NET_ZONE"; then
            _ts_net_fwd_add lan "$TS_NET_ZONE" && changed=1
        fi
    fi
    if [ "$changed" = "1" ]; then
        uci commit firewall
        return 0
    fi
    return 1
}

# Removes the zone named tailscale and every forwarding to/from it. UCI only,
# commits, never reloads. rc 0 = changed, 1 = no change.
ts_net_remove_zone() {
    local i
    local src
    local dest
    local idx
    local fwd
    local changed
    changed=0
    fwd=""
    i=0
    while src=$(uci -q get "firewall.@forwarding[$i].src"); do
        dest=$(uci -q get "firewall.@forwarding[$i].dest")
        if [ "$src" = "$TS_NET_ZONE" ] || [ "$dest" = "$TS_NET_ZONE" ]; then
            fwd="$i $fwd"   # prepend: delete highest index first
        fi
        i=$((i + 1))
    done
    for idx in $fwd; do
        uci -q delete "firewall.@forwarding[$idx]" && changed=1
    done
    if idx=$(_ts_net_own_zone_idx); then
        uci -q delete "firewall.@zone[$idx]" && changed=1
    fi
    if [ "$changed" = "1" ]; then
        uci commit firewall
        _ts_net_log "removed fw4 zone $TS_NET_ZONE"
        return 0
    fi
    return 1
}

ts_net_fw_reload() {
    /etc/init.d/firewall reload >/dev/null 2>&1
}

_ts_net_rule_v4_present() {
    ip rule show 2>/dev/null | grep "^$TS_NET_PREF:" | grep -qF "to $TS_NET_V4 lookup $TS_NET_TABLE"
}

_ts_net_rule_v6_present() {
    ip -6 rule show 2>/dev/null | grep "^$TS_NET_PREF:" | grep -qF "to $TS_NET_V6 lookup $TS_NET_TABLE"
}

# Idempotent. IPv6 is skipped silently when the kernel/ip lacks support.
ts_net_ensure_rules() {
    if ! _ts_net_rule_v4_present; then
        if ip rule add to "$TS_NET_V4" lookup "$TS_NET_TABLE" pref "$TS_NET_PREF" 2>/dev/null; then
            _ts_net_log "added ip rule pref $TS_NET_PREF to $TS_NET_V4 lookup $TS_NET_TABLE"
        fi
    fi
    if ! _ts_net_rule_v6_present; then
        ip -6 rule add to "$TS_NET_V6" lookup "$TS_NET_TABLE" pref "$TS_NET_PREF" >/dev/null 2>&1
    fi
    return 0
}

# Deletes every pref-1990 rule, v4 and v6 (capped so a stuck del cannot loop).
ts_net_remove_rules() {
    local n
    n=0
    while [ "$n" -lt 16 ] && ip rule del pref "$TS_NET_PREF" 2>/dev/null; do
        n=$((n + 1))
    done
    n=0
    while [ "$n" -lt 16 ] && ip -6 rule del pref "$TS_NET_PREF" 2>/dev/null; do
        n=$((n + 1))
    done
    return 0
}

# ts_net_remove_tiny_rules — after the Tiny package is removed: its init moved
# tailscaled's rules to prefs 1310-1370 (ahead of mwan3) and nothing deletes
# them once the package is gone. Only rules carrying tailscaled's fwmark or
# table 52 are touched, v4 and v6. Never call it while Tiny is installed.
ts_net_remove_tiny_rules() {
    local fam
    local p
    local n
    for fam in -4 -6; do
        for p in 1310 1330 1350 1370; do
            n=0
            while [ "$n" -lt 4 ] && ip "$fam" rule show pref "$p" 2>/dev/null \
                    | grep -qE 'fwmark 0x80000/0xff0000|lookup 52( |$)'; do
                ip "$fam" rule del pref "$p" 2>/dev/null || break
                n=$((n + 1))
            done
        done
    done
    return 0
}

# ts_net_apply [--no-reload] — rules + zone; fw4 reload only when the zone changed.
ts_net_apply() {
    ts_net_ensure_rules
    if ts_net_ensure_zone; then
        if [ "$1" != "--no-reload" ]; then
            ts_net_fw_reload
        fi
    fi
    return 0
}

ts_net_teardown() {
    ts_net_remove_rules
    if ts_net_remove_zone; then
        ts_net_fw_reload
    fi
    # Legacy cleanup of the retired mwan3 ipset hack. NetBird shares the range
    # and its own firewall lib may still rely on the entry.
    if ! command -v netbird >/dev/null 2>&1 && command -v ipset >/dev/null 2>&1; then
        ipset del mwan3_connected_ipv4 "$TS_NET_V4" >/dev/null 2>&1
    fi
    return 0
}

ts_net_status_json() {
    local en
    local zone
    local r4
    local r6
    en=false
    zone=false
    r4=false
    r6=false
    ts_net_enabled && en=true
    ts_net_zone_present && zone=true
    _ts_net_rule_v4_present && r4=true
    _ts_net_rule_v6_present && r6=true
    printf '{"enabled":%s,"zone":%s,"rule_v4":%s,"rule_v6":%s}\n' "$en" "$zone" "$r4" "$r6"
}
