#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/ethtool_helper.sh
# =============================================================================
# ethernet.sh — CGI Endpoint: Ethernet Status & Link Speed Limit (GET + POST)
# =============================================================================
# GET:  Reads ethernet interface status via sysfs and ethtool, plus the PCIe
#       ASPM policy (live + configured).
# POST: Sets link speed limit via ethtool and/or the PCIe ASPM policy, and
#       persists via UCI.
#
# Data sources:
#   /sys/class/net/eth0/operstate       -> link status (up/down)
#   /sys/class/net/eth0/speed           -> negotiated speed (Mbps)
#   /sys/class/net/eth0/duplex          -> duplex mode (full/half)
#   ethtool eth0                        -> auto-negotiation status
#   UCI quecmanager.eth_link.speed_limit -> configured speed limit
#   /sys/module/pcie_aspm/parameters/policy -> live ASPM policy (bracketed
#                                              token is the active one)
#   UCI quecmanager.eth_link.aspm_policy -> configured ASPM policy
#
# POST body (at least one field required):
#   { "speed_limit": "auto"|"10"|"100"|"1000"|"2500",
#     "aspm_policy": "default"|"performance"|"powersave"|"powersupersave" }
# ASPM is applied synchronously and never bounces the link; speed_limit keeps
# its async ethtool apply (link renegotiation).
#
# Ethtool advertise values (for restricted modes):
#   0x003          = 10baseT Half+Full              (10 Mbps only)
#   0x00f          = 10baseT + 100baseT Half+Full   (up to 100 Mbps)
#   0x02f          = 10/100 + 1000baseT Full        (up to 1000 Mbps)
#   0x80000000002f = above + 2500baseT/Full bit 47  (up to 2.5 Gbps)
#   auto           = all supported link mode names parsed from ethtool
#                    (covers 5G+ and any future modes that don't fit a fixed mask)
#
# Endpoint: GET/POST /cgi-bin/quecmanager/network/ethernet.sh
# Install location: /www/cgi-bin/quecmanager/network/ethernet.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_ethernet"
cgi_headers
cgi_handle_options

ETH_INTERFACE="eth0"
ASPM_POLICY_FILE="/sys/module/pcie_aspm/parameters/policy"

# --- Helper: active ASPM policy ------------------------------------------------
# File reads "default [performance] powersave powersupersave"; the bracketed
# token is active. Prints nothing when unsupported.
get_aspm_active() {
    [ -r "$ASPM_POLICY_FILE" ] || return 0
    sed -n 's/.*\[\([a-z]*\)\].*/\1/p' "$ASPM_POLICY_FILE" 2>/dev/null
}

# --- Helper: probe 2.5 Gbps support -------------------------------------------
# Returns "true" if ethtool reports 2500baseT/Full as a Supported link mode.
# Same parse window as get_supported_advertise_hex — kept inline to avoid
# re-running ethtool from the helper library on every GET.
probe_supports_2500() {
    if ! command -v ethtool >/dev/null 2>&1; then
        echo "false"
        return 0
    fi
    if ethtool "$ETH_INTERFACE" 2>/dev/null \
        | sed -n '/Supported link modes:/,/Supported pause frame use:/p' \
        | grep -q '2500baseT/Full'; then
        echo "true"
    else
        echo "false"
    fi
}

# --- Helper: ensure UCI section exists ----------------------------------------
ensure_uci_section() {
    if ! uci get quecmanager.eth_link >/dev/null 2>&1; then
        uci set quecmanager.eth_link=eth_link
        uci commit quecmanager
    fi
}

# --- Helper: get speed limit from UCI -----------------------------------------
get_speed_limit() {
    ensure_uci_section
    limit=$(uci get quecmanager.eth_link.speed_limit 2>/dev/null)
    echo "${limit:-auto}"
}

# --- Helper: map speed_limit to ethtool advertise hex -----------------------
# ethtool -s advertise only accepts hex values (%x), NOT mode names.
# For restricted modes (10/100/1000), hardcoded hex masks work fine.
# For "auto", we must dynamically build the hex mask from ethtool's
# "Supported link modes" output, because higher speeds like 2500baseT/Full
# (bit 47) don't fit in the old 0x82f mask.
get_advertise_value() {
    case "$1" in
        "10")   echo "0x003" ;;
        "100")  echo "0x00f" ;;
        "1000") echo "0x02f" ;;
        # 2500baseT/Full = bit 47 (linux/ethtool.h ETHTOOL_LINK_MODE_2500baseT_Full_BIT).
        # Cumulative with 1000baseT mask: hi=0x8000 (bit 47-32=15), lo=0x2f.
        # Format matches ethtool_helper.sh's printf "0x%x%08x" convention.
        "2500") echo "0x80000000002f" ;;
        *)      echo "" ;;
    esac
}

# --- Helper: build hex advertise mask from supported link modes --------------
# Parses "Supported link modes:" from ethtool, maps each mode name to its
# bit position (from linux/ethtool.h ETHTOOL_LINK_MODE_*_BIT), then builds
# the hex mask. Uses hi/lo 32-bit split so awk handles bit 47+ correctly.
# --- Helper: apply ethtool advertise settings --------------------------------
apply_speed_limit() {
    limit="$1"

    if [ "$limit" = "auto" ] || [ -z "$limit" ]; then
        # Auto: compute hex mask from all supported modes
        advertise=$(get_supported_advertise_hex)
        if [ -n "$advertise" ]; then
            ethtool -s "$ETH_INTERFACE" advertise "$advertise" autoneg on 2>/dev/null
        else
            # Fallback: just enable autoneg
            ethtool -s "$ETH_INTERFACE" autoneg on 2>/dev/null
        fi
    else
        advertise=$(get_advertise_value "$limit")
        ethtool -s "$ETH_INTERFACE" advertise "$advertise" autoneg on 2>/dev/null
    fi
}

# =============================================================================
# GET — Read ethernet status
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Reading ethernet status for $ETH_INTERFACE"

    # Check if interface exists
    if [ ! -d "/sys/class/net/$ETH_INTERFACE" ]; then
        qlog_error "Interface $ETH_INTERFACE not found"
        jq -n '{success: false, error: "interface_not_found", detail: "Ethernet interface not found"}'
        exit 0
    fi

    # Read link status from sysfs
    link_status="down"
    if [ -f "/sys/class/net/$ETH_INTERFACE/operstate" ]; then
        link_status=$(cat "/sys/class/net/$ETH_INTERFACE/operstate" 2>/dev/null)
    fi

    # Read speed from sysfs (returns -1 or error if link is down)
    speed=""
    if [ -f "/sys/class/net/$ETH_INTERFACE/speed" ]; then
        raw_speed=$(cat "/sys/class/net/$ETH_INTERFACE/speed" 2>/dev/null)
        if [ -n "$raw_speed" ] && [ "$raw_speed" -gt 0 ] 2>/dev/null; then
            speed="${raw_speed}Mb/s"
        fi
    fi

    # Read duplex from sysfs
    duplex=""
    if [ -f "/sys/class/net/$ETH_INTERFACE/duplex" ]; then
        duplex=$(cat "/sys/class/net/$ETH_INTERFACE/duplex" 2>/dev/null)
    fi

    # Read auto-negotiation from ethtool
    auto_neg=""
    if command -v ethtool >/dev/null 2>&1; then
        eth_output=$(ethtool "$ETH_INTERFACE" 2>/dev/null)
        if [ -n "$eth_output" ]; then
            auto_neg=$(printf '%s' "$eth_output" | grep "Auto-negotiation:" | awk '{print $2}')
            # Fallback: get speed from ethtool if sysfs didn't work
            if [ -z "$speed" ]; then
                speed=$(printf '%s' "$eth_output" | grep "Speed:" | awk '{print $2}')
            fi
            # Fallback: get duplex from ethtool if sysfs didn't work
            if [ -z "$duplex" ]; then
                duplex=$(printf '%s' "$eth_output" | grep "Duplex:" | awk '{print $2}')
            fi
        fi
    fi

    # Get configured speed limit from UCI
    speed_limit=$(get_speed_limit)
    supports_2500=$(probe_supports_2500)

    aspm_supported="false"
    aspm_policy=""
    if [ -r "$ASPM_POLICY_FILE" ]; then
        aspm_supported="true"
        aspm_policy=$(get_aspm_active)
    fi
    aspm_configured=$(uci -q get quecmanager.eth_link.aspm_policy 2>/dev/null)

    # Set defaults for missing values
    [ -z "$speed" ] && speed="Unknown"
    [ -z "$duplex" ] && duplex="Unknown"
    [ -z "$auto_neg" ] && auto_neg="Unknown"

    qlog_info "Status: link=$link_status speed=$speed duplex=$duplex autoneg=$auto_neg limit=$speed_limit"

    jq -n \
        --arg link_status "$link_status" \
        --arg speed "$speed" \
        --arg duplex "$duplex" \
        --arg auto_negotiation "$auto_neg" \
        --arg speed_limit "$speed_limit" \
        --argjson supports_2500 "$supports_2500" \
        --argjson aspm_supported "$aspm_supported" \
        --arg aspm_policy "$aspm_policy" \
        --arg aspm_configured "$aspm_configured" \
        '{
            success: true,
            link_status: $link_status,
            speed: $speed,
            duplex: $duplex,
            auto_negotiation: $auto_negotiation,
            speed_limit: $speed_limit,
            supports_2500: $supports_2500,
            aspm_supported: $aspm_supported,
            aspm_policy: $aspm_policy,
            aspm_configured: $aspm_configured
        }'
    exit 0
fi

# =============================================================================
# POST — Set link speed limit
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    speed_limit=$(printf '%s' "$POST_DATA" | jq -r '.speed_limit // empty')

    aspm_req=$(printf '%s' "$POST_DATA" | jq -r '.aspm_policy // empty')

    if [ -z "$speed_limit" ] && [ -z "$aspm_req" ]; then
        cgi_error "missing_field" "speed_limit or aspm_policy field is required"
        exit 0
    fi

    if [ -n "$speed_limit" ]; then
        case "$speed_limit" in
            auto|10|100|1000|2500) ;;
            *)
                cgi_error "invalid_value" "speed_limit must be: auto, 10, 100, 1000, or 2500"
                exit 0
                ;;
        esac
    fi

    if [ -n "$aspm_req" ]; then
        case "$aspm_req" in
            default|performance|powersave|powersupersave) ;;
            *)
                cgi_error "invalid_value" "aspm_policy must be: default, performance, powersave, or powersupersave"
                exit 0
                ;;
        esac
        if [ ! -w "$ASPM_POLICY_FILE" ]; then
            cgi_error "aspm_unsupported" "PCIe ASPM policy is not supported on this device"
            exit 0
        fi
    fi

    if [ -n "$speed_limit" ]; then
        if ! command -v ethtool >/dev/null 2>&1; then
            qlog_error "ethtool not installed"
            cgi_error "ethtool_missing" "ethtool is not installed on this device"
            exit 0
        fi

        if ! ip link show "$ETH_INTERFACE" >/dev/null 2>&1; then
            qlog_error "Interface $ETH_INTERFACE not found"
            cgi_error "interface_not_found" "Ethernet interface not found"
            exit 0
        fi
    fi

    init_script="/etc/init.d/qmanager_eth_link"
    aspm_active=""

    # --- ASPM: synchronous, no link bounce ------------------------------------
    if [ -n "$aspm_req" ]; then
        qlog_info "Setting PCIe ASPM policy to: $aspm_req"

        ensure_uci_section
        uci set quecmanager.eth_link.aspm_policy="$aspm_req" 2>/dev/null
        if ! uci commit quecmanager 2>/dev/null; then
            qlog_error "uci commit failed for aspm_policy=$aspm_req"
            cgi_error "save_failed" "Failed to persist ASPM policy"
            exit 0
        fi

        if [ -x "$init_script" ]; then
            "$init_script" enable 2>/dev/null
        fi

        echo "$aspm_req" > "$ASPM_POLICY_FILE" 2>/dev/null
        aspm_active=$(get_aspm_active)
        if [ "$aspm_active" != "$aspm_req" ]; then
            qlog_error "ASPM apply mismatch: requested=$aspm_req active=${aspm_active:-unknown}"
            cgi_error "aspm_apply_failed" "Kernel did not accept the ASPM policy"
            exit 0
        fi
        qlog_info "ASPM policy applied: $aspm_active"
    fi

    # --- ASPM only: respond now -----------------------------------------------
    if [ -z "$speed_limit" ]; then
        jq -n --arg aspm_policy "$aspm_active" \
            '{success: true, apply_in_progress: false, aspm_policy: $aspm_policy}'
        exit 0
    fi

    qlog_info "Setting link speed limit to: $speed_limit"

    # --- Persist to UCI BEFORE applying (cheap, no link bounce) --------------
    ensure_uci_section
    uci set quecmanager.eth_link.speed_limit="$speed_limit" 2>/dev/null

    if ! uci commit quecmanager 2>/dev/null; then
        qlog_error "uci commit failed for speed_limit=$speed_limit"
        cgi_error "save_failed" "Failed to persist link speed setting"
        exit 0
    fi

    # Setup boot persistence (cheap)
    if [ -x "$init_script" ]; then
        "$init_script" enable 2>/dev/null
    fi

    qlog_info "Link speed limit saved: $speed_limit (applying asynchronously)"

    # --- Emit HTTP response BEFORE the PHY link bounce -----------------------
    # ethtool -s / ethtool -r cause a 2-5 s link renegotiation that kills
    # in-flight HTTP responses. Send the JSON first, then background the
    # apply so the client never sees a spurious network error.
    jq -n --arg speed_limit "$speed_limit" --arg aspm_policy "$aspm_active" '{
        success: true,
        apply_in_progress: true,
        disconnect_window_seconds: 5,
        speed_limit: $speed_limit
    } + (if $aspm_policy != "" then {aspm_policy: $aspm_policy} else {} end)'

    # --- Fire-and-forget ethtool apply (double-fork) -------------------------
    # 1 s delay ensures HTTP bytes flush before the PHY bounce.
    ( (
        sleep 1
        apply_speed_limit "$speed_limit"
        ethtool -r "$ETH_INTERFACE" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 & )

    exit 0
fi

# --- Method not allowed -------------------------------------------------------
cgi_method_not_allowed
