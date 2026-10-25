#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# lan_config.sh — CGI Endpoint: LAN Bridge Address / Subnet (GET + POST)
# =============================================================================
# Reads and edits the LAN bridge (br-lan) IPv4 address and subnet mask.
#
# "Gateway" in the UI == the router's own LAN IP (network.lan.ipaddr); LAN
# clients use it as their default gateway. Subnet == network.lan.netmask.
# A LAN bridge has NO network.lan.gateway key — this endpoint never creates
# one.
#
# All IP/netmask validation + math is done in pure POSIX shell arithmetic.
# ipcalc.sh is NOT used as a validator: it silently wraps invalid octets
# mod 256 and exits 0. Device jq has no regex (test/match/sub/gsub), so
# parsing stays in shell.
#
# GET:  Returns current br-lan ipaddr, netmask, and derived CIDR prefix.
# GET response:
#   { success, device, ipaddr, netmask, prefix }
#
# POST body:   { "ipaddr": "192.168.1.1", "prefix": 24 }
# POST response (emitted BEFORE the apply that severs this connection):
#   { success, apply_in_progress, disconnect_window_seconds, carrier_bounce,
#     new_ipaddr, netmask, prefix }
# Apply: fire-and-forget `/etc/init.d/network reload` (rebinds br-lan from
#        UCI without a reboot). When the address/netmask actually changed, the
#        apply ALSO reloads dnsmasq and physically carrier-bounces the LAN
#        bridge member port(s) (ip link down/up). `network reload` rebinds
#        br-lan but never drops the physical port's carrier, so a cable-sense
#        upstream router (e.g. GL.iNet Flint 2 in WAN/DHCP mode) keeps its
#        stale lease/gateway. The carrier bounce forces it to re-DHCP into the
#        new subnet. An independent watchdog force-ups every member after 15 s
#        so an interrupted bounce can never strand the LAN. The response
#        reports `carrier_bounce` (true only when armed). Never reboot /
#        AT+CFUN here.
#
# Endpoint: GET/POST /cgi-bin/quecmanager/network/lan_config.sh
# Install location: /www/cgi-bin/quecmanager/network/lan_config.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_lan_config"
cgi_headers
cgi_handle_options

# --- Events (for append_event) -----------------------------------------------
EVENTS_FILE="/tmp/qmanager_events.json"
MAX_EVENTS=50
if [ -f /usr/lib/qmanager/events.sh ]; then
    . /usr/lib/qmanager/events.sh
else
    append_event() { :; }
fi

# --- Helper: count set bits in a dotted netmask -> CIDR prefix ---------------
# Echoes the prefix (0-32). Echoes empty string on a malformed mask.
netmask_to_prefix() {
    _nm="$1"
    _o1=$(printf '%s' "$_nm" | cut -d. -f1)
    _o2=$(printf '%s' "$_nm" | cut -d. -f2)
    _o3=$(printf '%s' "$_nm" | cut -d. -f3)
    _o4=$(printf '%s' "$_nm" | cut -d. -f4)
    case "$_o1$_o2$_o3$_o4" in
        ''|*[!0-9]*)
            echo ""
            return 0
            ;;
    esac
    _bits=0
    for _oct in "$_o1" "$_o2" "$_o3" "$_o4"; do
        if [ "$_oct" -gt 255 ] 2>/dev/null; then
            echo ""
            return 0
        fi
        _v="$_oct"
        while [ "$_v" -gt 0 ]; do
            _bits=$(( _bits + (_v & 1) ))
            _v=$(( _v >> 1 ))
        done
    done
    echo "$_bits"
}

# --- Helper: CIDR prefix -> dotted netmask -----------------------------------
# Echoes the dotted netmask for a prefix in 0..32.
prefix_to_netmask() {
    _p="$1"
    if [ "$_p" -eq 0 ]; then
        _mask=0
    else
        # 32-bit mask with the top _p bits set.
        _mask=$(( 0xFFFFFFFF ^ ( (1 << (32 - _p)) - 1 ) ))
        _mask=$(( _mask & 0xFFFFFFFF ))
    fi
    echo "$(( (_mask >> 24) & 255 )).$(( (_mask >> 16) & 255 )).$(( (_mask >> 8) & 255 )).$(( _mask & 255 ))"
}

# --- Helper: dotted IP -> 32-bit integer -------------------------------------
ip_to_int() {
    _ip="$1"
    _a=$(printf '%s' "$_ip" | cut -d. -f1)
    _b=$(printf '%s' "$_ip" | cut -d. -f2)
    _c=$(printf '%s' "$_ip" | cut -d. -f3)
    _d=$(printf '%s' "$_ip" | cut -d. -f4)
    echo "$(( (_a << 24) | (_b << 16) | (_c << 8) | _d ))"
}

# =============================================================================
# GET — Read current LAN address + subnet
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Reading LAN config"

    ipaddr=$(uci -q get network.lan.ipaddr 2>/dev/null)
    netmask=$(uci -q get network.lan.netmask 2>/dev/null)
    device=$(uci -q get network.lan.device 2>/dev/null)
    [ -z "$device" ] && device="br-lan"

    if [ -z "$ipaddr" ] || [ -z "$netmask" ]; then
        qlog_error "Unable to read network.lan.ipaddr/netmask"
        cgi_error "lan_read_failed" "Unable to read LAN address or netmask"
        exit 0
    fi

    prefix=$(netmask_to_prefix "$netmask")
    if [ -z "$prefix" ]; then
        qlog_error "Malformed netmask in UCI: $netmask"
        cgi_error "lan_read_failed" "Stored netmask is malformed"
        exit 0
    fi

    qlog_info "LAN: device=$device ipaddr=$ipaddr netmask=$netmask prefix=$prefix"
    jq -n \
        --arg device "$device" \
        --arg ipaddr "$ipaddr" \
        --arg netmask "$netmask" \
        --argjson prefix "$prefix" \
        '{
            success: true,
            device: $device,
            ipaddr: $ipaddr,
            netmask: $netmask,
            prefix: $prefix
        }'
    exit 0
fi

# =============================================================================
# POST — Set LAN address + subnet, then reload network (fire-and-forget)
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    # --- Parse ipaddr ---------------------------------------------------------
    # Don't use `// default` — jq's `//` coalesces on false AND null. Validate
    # object/presence/type explicitly via has() + type (matching wol.sh).
    ipaddr=$(printf '%s' "$POST_DATA" | jq -r '
        if type != "object" then " not_object"
        elif has("ipaddr") | not then " missing"
        elif (.ipaddr | type) != "string" then " not_string"
        else .ipaddr
        end
    ' 2>/dev/null)
    case "$ipaddr" in
        ""|*not_object*|*missing*|*not_string*)
            # Leading NUL guards against an attacker-supplied literal that
            # happens to equal one of the sentinels.
            cgi_error "invalid_ipaddr" "ipaddr must be a non-empty string"
            exit 0
            ;;
    esac

    # --- Parse prefix ---------------------------------------------------------
    prefix=$(printf '%s' "$POST_DATA" | jq -r '
        if type != "object" then "not_object"
        elif has("prefix") | not then "missing"
        elif (.prefix | type) != "number" then "not_number"
        elif (.prefix != (.prefix | floor)) then "not_integer"
        else (.prefix | tostring)
        end
    ' 2>/dev/null)
    case "$prefix" in
        ''|*[!0-9]*)
            cgi_error "invalid_prefix" "prefix must be an integer between 16 and 30"
            exit 0
            ;;
    esac
    if [ "$prefix" -lt 16 ] || [ "$prefix" -gt 30 ]; then
        cgi_error "invalid_prefix" "prefix must be an integer between 16 and 30"
        exit 0
    fi

    # --- Validate ipaddr: exactly 4 numeric octets, each 0-255 ---------------
    # Reject empty/extra parts and any non-digit content. A 5th field via an
    # extra dot would leave o4 holding "x.y" -> caught by the digit guard.
    o1=$(printf '%s' "$ipaddr" | cut -d. -f1)
    o2=$(printf '%s' "$ipaddr" | cut -d. -f2)
    o3=$(printf '%s' "$ipaddr" | cut -d. -f3)
    o4=$(printf '%s' "$ipaddr" | cut -d. -f4)
    o5=$(printf '%s' "$ipaddr" | cut -d. -f5)

    if [ -n "$o5" ]; then
        cgi_error "invalid_ipaddr" "Address must be four octets"
        exit 0
    fi
    for oct in "$o1" "$o2" "$o3" "$o4"; do
        case "$oct" in
            ''|*[!0-9]*)
                cgi_error "invalid_ipaddr" "Each octet must be a number 0-255"
                exit 0
                ;;
        esac
        # Reject leading-zero forms (e.g. "01") that confuse arithmetic and
        # are non-canonical. A bare "0" is fine.
        if [ "${#oct}" -gt 1 ]; then
            case "$oct" in
                0*)
                    cgi_error "invalid_ipaddr" "Octets must not have leading zeros"
                    exit 0
                    ;;
            esac
        fi
        if [ "$oct" -gt 255 ]; then
            cgi_error "invalid_ipaddr" "Each octet must be 0-255"
            exit 0
        fi
    done

    # --- Reject non-unicast / reserved hosts ----------------------------------
    # First octet 1-223 and not 127 (loopback). Rejects 0.0.0.0, multicast
    # (224+), and class-E.
    if [ "$o1" -lt 1 ] || [ "$o1" -gt 223 ] || [ "$o1" -eq 127 ]; then
        cgi_error "invalid_ipaddr" "Address must be a usable unicast host"
        exit 0
    fi

    # --- Compute netmask from prefix ------------------------------------------
    netmask=$(prefix_to_netmask "$prefix")

    # --- Reject network / broadcast address of the resulting subnet ----------
    ip_int=$(ip_to_int "$ipaddr")
    mask_int=$(( 0xFFFFFFFF ^ ( (1 << (32 - prefix)) - 1 ) ))
    mask_int=$(( mask_int & 0xFFFFFFFF ))
    net_int=$(( ip_int & mask_int ))
    bcast_int=$(( net_int | (mask_int ^ 0xFFFFFFFF) ))

    if [ "$ip_int" -eq "$net_int" ] || [ "$ip_int" -eq "$bcast_int" ]; then
        cgi_error "invalid_host_in_subnet" "Address is the network/broadcast address for /$prefix"
        exit 0
    fi

    qlog_info "Applying LAN config: ipaddr=$ipaddr netmask=$netmask prefix=$prefix"

    # --- Capture pre-change config to decide whether a carrier bounce is warranted.
    OLD_IP=$(uci -q get network.lan.ipaddr 2>/dev/null)
    OLD_MASK=$(uci -q get network.lan.netmask 2>/dev/null)
    LAN_CHANGED=0
    if [ "$OLD_IP" != "$ipaddr" ] || [ "$OLD_MASK" != "$netmask" ]; then
        LAN_CHANGED=1
    fi

    # --- Physical port(s) to carrier-bounce so cable-sense routers re-DHCP. ---
    # Derive from the bridge's kernel member list; fall back to the device
    # itself if it isn't a bridge. No hardcoded eth0.
    LAN_DEV=$(uci -q get network.lan.device 2>/dev/null)
    [ -z "$LAN_DEV" ] && LAN_DEV="br-lan"
    if [ -d "/sys/class/net/$LAN_DEV/brif" ]; then
        LAN_MEMBERS=$(ls "/sys/class/net/$LAN_DEV/brif" 2>/dev/null | tr '\n' ' ')
    else
        LAN_MEMBERS="$LAN_DEV"
    fi

    # --- Persist to UCI -------------------------------------------------------
    uci set network.lan.ipaddr="$ipaddr" 2>/dev/null
    uci set network.lan.netmask="$netmask" 2>/dev/null
    if ! uci commit network 2>/dev/null; then
        qlog_error "uci commit network failed"
        cgi_error "lan_save_failed" "Failed to persist LAN settings"
        exit 0
    fi

    append_event "lan_address_changed" "LAN address changed to $ipaddr/$prefix" "info"

    # --- Emit HTTP response BEFORE the network reload severs this connection -
    # Report whether a carrier bounce is armed and a realistic window for it.
    if [ "$LAN_CHANGED" = "1" ]; then
        _bounce=true
        _window=30
    else
        _bounce=false
        _window=5
    fi
    jq -n \
        --arg new_ipaddr "$ipaddr" \
        --arg netmask "$netmask" \
        --argjson prefix "$prefix" \
        --argjson carrier_bounce "$_bounce" \
        --argjson disconnect_window_seconds "$_window" \
        '{
            success: true,
            apply_in_progress: true,
            disconnect_window_seconds: $disconnect_window_seconds,
            carrier_bounce: $carrier_bounce,
            new_ipaddr: $new_ipaddr,
            netmask: $netmask,
            prefix: $prefix
        }'

    # --- Fire-and-forget: reload network, then carrier-bounce the LAN port(s) -
    # The 1 s delay flushes HTTP bytes before br-lan rebinds. When the address
    # actually changed, we also reload dnsmasq (so it serves the new pool) and
    # then physically bounce each bridge member's carrier — this is what makes a
    # cable-sense upstream router (e.g. Flint 2) drop its stale lease and
    # re-DHCP into the new subnet with the new gateway. `network reload` alone
    # never drops carrier, so the router would otherwise keep the old lease.
    # An independent watchdog force-ups every member after 15 s so an
    # interrupted bounce can never strand the LAN. NEVER reboot / AT+CFUN here.
    ( (
        sleep 1
        /etc/init.d/network reload
        if [ "$LAN_CHANGED" = "1" ]; then
            /etc/init.d/dnsmasq reload
            # Safety net: guarantee links return even if the bounce is killed.
            ( ( sleep 15
                for _m in $LAN_MEMBERS; do ip link set "$_m" up 2>/dev/null; done
              ) </dev/null >/dev/null 2>&1 & )
            sleep 3
            # Word-splitting of $LAN_MEMBERS is intentional (iterate members).
            for _m in $LAN_MEMBERS; do ip link set "$_m" down 2>/dev/null; done
            sleep 4
            for _m in $LAN_MEMBERS; do ip link set "$_m" up 2>/dev/null; done
        fi
    ) </dev/null >/dev/null 2>&1 & )

    exit 0
fi

# --- Method not allowed -------------------------------------------------------
cgi_method_not_allowed
