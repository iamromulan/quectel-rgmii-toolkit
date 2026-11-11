#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# lan_devices.sh -- CGI Endpoint: Connected LAN Devices (GET-only, read-only)
# =============================================================================
# Lists devices visible on the LAN, merged from two sources so both DHCP
# clients (named) and static-IP devices (unnamed) show up. Backs the
# additive MAC-picker dropdown on the IP Passthrough page. Does NOT touch
# the IPPT apply pipeline -- this is a standalone read endpoint.
#
# Data sources (merged, deduped by MAC -- lease wins on conflict):
#   1. DHCP leases (primary, gives hostnames)
#      Lease file path is UCI-overridden on this hardware -- resolved via
#      `uci -q get dhcp.lan_dns.leasefile`, falling back to /tmp/dhcp.leases.
#      Line format: <epoch> <mac> <ip> <hostname> <clientid>
#      hostname "*" (unknown) is normalized to "".
#   2. `ip neigh show` (secondary, catches static-IP devices with no lease),
#      falling back to /proc/net/arp when `ip` is unavailable.
#
# Endpoint: GET /cgi-bin/quecmanager/network/lan_devices.sh
# Install location: /www/cgi-bin/quecmanager/network/lan_devices.sh
# =============================================================================

qlog_init "cgi_lan_devices"
cgi_headers
cgi_handle_options

# --- GET only ------------------------------------------------------------
if [ "$REQUEST_METHOD" != "GET" ]; then
    cgi_method_not_allowed
    exit 0
fi

# --- Cleanup for temp files ------------------------------------------------
OUT_FILE="/tmp/qmanager_lan_devices.$$"
SEEN_FILE="/tmp/qmanager_lan_devices_seen.$$"
cleanup() {
    rm -f "$OUT_FILE" "$SEEN_FILE"
}
trap cleanup EXIT INT TERM
: > "$OUT_FILE"
: > "$SEEN_FILE"

# --- Helper: Validate MAC address (XX:XX:XX:XX:XX:XX) ----------------------
validate_mac() {
    case "$1" in
        [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
        *) return 1 ;;
    esac
}

qlog_info "Listing connected LAN devices"

# =============================================================================
# 1. DHCP leases (primary -- gives hostnames)
# =============================================================================
LEASE_FILE=$(uci -q get dhcp.lan_dns.leasefile)
[ -n "$LEASE_FILE" ] || LEASE_FILE="/tmp/dhcp.leases"
qlog_debug "lease file: $LEASE_FILE"

if [ -f "$LEASE_FILE" ] && [ -r "$LEASE_FILE" ]; then
    while read -r lease_epoch lease_mac lease_ip lease_host lease_clientid; do
        [ -n "$lease_mac" ] || continue
        mac_lc=$(printf '%s' "$lease_mac" | tr 'A-F' 'a-f')
        validate_mac "$mac_lc" || continue
        case "$lease_host" in
            '*'|'') lease_host="" ;;
        esac
        grep -qx "$mac_lc" "$SEEN_FILE" 2>/dev/null && continue
        printf '%s\n' "$mac_lc" >> "$SEEN_FILE"
        printf '%s\t%s\t%s\n' "$mac_lc" "$lease_ip" "$lease_host" >> "$OUT_FILE"
    done < "$LEASE_FILE"
fi

# =============================================================================
# 2. Neighbour/ARP table (secondary -- catches static-IP devices with no lease)
# =============================================================================
if command -v ip >/dev/null 2>&1; then
    neigh_raw=$(ip neigh show 2>/dev/null | awk '
        {
            n_ip = $1; n_mac = ""; n_state = $NF
            for (i = 1; i <= NF; i++) {
                if ($i == "lladdr") { n_mac = $(i + 1) }
            }
            if (n_mac != "" && n_state != "FAILED" && n_state != "INCOMPLETE") {
                print n_ip "\t" n_mac
            }
        }')
elif [ -f /proc/net/arp ]; then
    neigh_raw=$(awk 'NR > 1 && $4 != "00:00:00:00:00:00" && $3 != "0x0" { print $1 "\t" $4 }' /proc/net/arp 2>/dev/null)
else
    neigh_raw=""
fi

if [ -n "$neigh_raw" ]; then
    printf '%s\n' "$neigh_raw" | while read -r n_ip n_mac; do
        [ -n "$n_mac" ] || continue
        mac_lc=$(printf '%s' "$n_mac" | tr 'A-F' 'a-f')
        validate_mac "$mac_lc" || continue
        grep -qx "$mac_lc" "$SEEN_FILE" 2>/dev/null && continue
        printf '%s\n' "$mac_lc" >> "$SEEN_FILE"
        printf '%s\t%s\t%s\n' "$mac_lc" "$n_ip" "" >> "$OUT_FILE"
    done
fi

# =============================================================================
# 3. Assemble response
#    split() on a literal string is NOT regex -- safe on device jq, which has
#    no Oniguruma (test/match/sub/gsub are unavailable at runtime).
# =============================================================================
devices_json=$(jq -R -s '
    split("\n")
    | map(select(length > 0) | split("\t") | {mac: .[0], ip: .[1], hostname: .[2]})
' "$OUT_FILE" 2>/dev/null)
[ -n "$devices_json" ] || devices_json="[]"

qlog_info "LAN devices response assembled"

jq -n --argjson devices "$devices_json" '{success: true, devices: $devices}'
exit 0
