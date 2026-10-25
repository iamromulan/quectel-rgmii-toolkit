#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/cgi_at.sh
# =============================================================================
# about.sh -- CGI Endpoint: About Device (GET-only)
# =============================================================================
# Gathers device identity, network addresses, 3GPP release info, public IPs,
# and OpenWRT system info into a single JSON response.
#
# Data sources:
#   /tmp/qmanager_status.json       -> Poller cache (firmware, IMEI, WAN IPs,
#                                      ping daemon reachability verdict)
#   AT+QNWCFG="3gpp_rel"           -> 3GPP release versions (LTE, NR5G)
#   uci get network.lan.ipaddr      -> OpenWRT br-lan IP (device IP)
#   uci get network.lan.netmask     -> OpenWRT br-lan netmask (for CIDR subnet)
#   https://api.ipify.org           -> Public IPv4 address only (3s timeout,
#                                      non-blocking); never the reachability verdict
#   https://api6.ipify.org          -> Public IPv6 (3s timeout, non-blocking)
#   /etc/openwrt_release            -> OpenWRT version
#   uname -r                       -> Linux kernel version
#
# Endpoint: GET /cgi-bin/quecmanager/device/about.sh
# Install location: /www/cgi-bin/quecmanager/device/about.sh
# =============================================================================

qlog_init "cgi_about"
cgi_headers
cgi_handle_options

CACHE_FILE="/tmp/qmanager_status.json"
CMD_GAP=0.2
PUB_IP_TIMEOUT=3

# --- Cleanup for temp files --------------------------------------------------
pub4_file="/tmp/qmanager_pub_ipv4.$$"
pub6_file="/tmp/qmanager_pub_ipv6.$$"
cleanup() {
    rm -f "$pub4_file" "$pub6_file"
}
trap cleanup EXIT INT TERM

# --- GET only ----------------------------------------------------------------
if [ "$REQUEST_METHOD" != "GET" ]; then
    cgi_method_not_allowed
    exit 0
fi

# =============================================================================
# 1. Fire off public IP fetches FIRST (background, non-blocking)
#    These run in parallel while we do everything else.
# =============================================================================
if command -v curl >/dev/null 2>&1; then
    # -L: follow redirects. TLS is verified like every other fetch here; with
    # no CA bundle the lookup fails and the public IP is simply left blank.
    ( curl -sL --max-time "$PUB_IP_TIMEOUT" https://api.ipify.org > "$pub4_file" 2>/dev/null ) &
    pid4=$!
    ( curl -sL --max-time "$PUB_IP_TIMEOUT" https://api6.ipify.org > "$pub6_file" 2>/dev/null ) &
    pid6=$!
else
    pid4=""
    pid6=""
fi

# =============================================================================
# 2. Read poller cache (single jq call)
# =============================================================================
c_firmware=""
c_build_date=""
c_manufacturer=""
c_model=""
c_imei=""
c_wan_ipv4=""
c_wan_ipv6=""
# Reachability is the ping daemon's verdict, the one source every surface reads.
# "null" = not reporting; a jq `//` would turn a real false into the fallback.
c_inet="null"
c_inet_family=""
c_inet_latency="null"

if [ -f "$CACHE_FILE" ]; then
    eval "$(jq -r '
        @sh "c_firmware=\(.device.firmware // "")",
        @sh "c_build_date=\(.device.build_date // "")",
        @sh "c_manufacturer=\(.device.manufacturer // "")",
        @sh "c_model=\(.device.model // "")",
        @sh "c_imei=\(.device.imei // "")",
        @sh "c_wan_ipv4=\(.network.wan_ipv4 // "")",
        @sh "c_wan_ipv6=\(.network.wan_ipv6 // "")",
        @sh "c_inet=\(if (.connectivity.internet_available | type) == "boolean" then (.connectivity.internet_available | tostring) else "null" end)",
        @sh "c_inet_family=\(.connectivity.last_family // "")",
        @sh "c_inet_latency=\(if (.connectivity.latency_ms | type) == "number" then (.connectivity.latency_ms | tostring) else "null" end)"
    ' "$CACHE_FILE" 2>/dev/null)"
fi

# --argjson needs valid JSON; a missing or garbled cache falls back to null.
case "$c_inet" in true|false) ;; *) c_inet="null" ;; esac
case "$c_inet_latency" in
    ''|*[!0-9.]*|*.*.*|.*|*.) c_inet_latency="null" ;;
esac

# =============================================================================
# 3. AT commands for data not in the poller cache
# =============================================================================
rel_lte=""
rel_nr5g=""

# 3GPP release versions -- +QNWCFG: "3gpp_rel",R17,R17
# Read-only display field: a transport failure or ERROR leaves both empty
# (shown as unknown) instead of failing the whole page; at_exec logs it.
line=""
if at_exec 'AT+QNWCFG="3gpp_rel"'; then
    line=$(printf '%s\n' "$AT_RAW" | grep '+QNWCFG:.*"3gpp_rel"' | head -1 | tr -d '\r ')
fi
if [ -n "$line" ]; then
    rel_lte=$(printf '%s' "$line" | cut -d',' -f2)
    rel_nr5g=$(printf '%s' "$line" | cut -d',' -f3)
fi

# OpenWRT LAN info (br-lan) -- NOT the modem's internal RNDIS/ECM subnet.
# AT+QMAP="LANIP" would report the modem-host USB link (default 192.168.224.x),
# which is not what users think of as their LAN. UCI is authoritative.
lan_ip=$(uci get network.lan.ipaddr 2>/dev/null | cut -d'/' -f1)
lan_netmask=$(uci get network.lan.netmask 2>/dev/null)
lan_subnet=""

if [ -n "$lan_ip" ] && [ -n "$lan_netmask" ]; then
    OLDIFS=$IFS
    IFS=.
    set -- $lan_ip
    i1=${1:-0}; i2=${2:-0}; i3=${3:-0}; i4=${4:-0}
    set -- $lan_netmask
    m1=${1:-0}; m2=${2:-0}; m3=${3:-0}; m4=${4:-0}
    IFS=$OLDIFS

    prefix=0
    for octet in $m1 $m2 $m3 $m4; do
        while [ "$octet" -gt 0 ]; do
            prefix=$((prefix + (octet & 1)))
            octet=$((octet >> 1))
        done
    done

    lan_subnet=$(printf '%d.%d.%d.%d/%d' \
        "$((i1 & m1))" "$((i2 & m2))" "$((i3 & m3))" "$((i4 & m4))" "$prefix")
fi

# =============================================================================
# 4. OpenWRT system info
# =============================================================================
sys_hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo "")
sys_kernel=$(uname -r 2>/dev/null || echo "")
sys_openwrt=""
if [ -f /etc/openwrt_release ]; then
    sys_openwrt=$(. /etc/openwrt_release && echo "$DISTRIB_RELEASE")
fi

# =============================================================================
# 5. Collect public IP results (wait for background jobs, bounded by timeout)
# =============================================================================
public_ipv4=""
public_ipv6=""

[ -n "$pid4" ] && wait "$pid4" 2>/dev/null
[ -n "$pid6" ] && wait "$pid6" 2>/dev/null

# Read and validate (basic sanity: no HTML, no error pages)
if [ -f "$pub4_file" ]; then
    raw=$(cat "$pub4_file" 2>/dev/null | tr -d '\n\r ')
    case "$raw" in
        *"<"*|"") ;;  # HTML or empty — skip
        *) public_ipv4="$raw" ;;
    esac
fi
if [ -f "$pub6_file" ]; then
    raw=$(cat "$pub6_file" 2>/dev/null | tr -d '\n\r ')
    case "$raw" in
        *"<"*|"") ;;
        *) public_ipv6="$raw" ;;
    esac
fi

# =============================================================================
# 6. Build JSON response
# =============================================================================
jq -n \
    --arg model "$c_model" \
    --arg mfr "$c_manufacturer" \
    --arg firmware "$c_firmware" \
    --arg build_date "$c_build_date" \
    --arg imei "$c_imei" \
    --arg rel_lte "$rel_lte" \
    --arg rel_nr5g "$rel_nr5g" \
    --arg device_ip "$lan_ip" \
    --arg lan_sn "$lan_subnet" \
    --arg wan4 "$c_wan_ipv4" \
    --arg wan6 "$c_wan_ipv6" \
    --arg pub4 "$public_ipv4" \
    --arg pub6 "$public_ipv6" \
    --arg hostname "$sys_hostname" \
    --arg kernel "$sys_kernel" \
    --arg owrt "$sys_openwrt" \
    --argjson inet "$c_inet" \
    --arg inet_family "$c_inet_family" \
    --argjson inet_latency "$c_inet_latency" \
    '{
        success: true,
        device: {
            model: $model,
            manufacturer: $mfr,
            firmware: $firmware,
            build_date: $build_date,
            imei: $imei
        },
        "3gpp_release": {
            lte: $rel_lte,
            nr5g: $rel_nr5g
        },
        network: {
            device_ip: $device_ip,
            lan_subnet: $lan_sn,
            wan_ipv4: $wan4,
            wan_ipv6: $wan6,
            public_ipv4: $pub4,
            public_ipv6: $pub6
        },
        system: {
            hostname: $hostname,
            kernel_version: $kernel,
            openwrt_version: $owrt
        },
        connectivity: {
            internet_available: $inet,
            last_family: $inet_family,
            latency_ms: $inet_latency
        }
    }'
