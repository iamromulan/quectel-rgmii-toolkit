#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# dns.sh — CGI Endpoint: Custom DNS Configuration (GET + POST)
# =============================================================================
# GET:  Reads current DNS mode and configured DNS servers from UCI.
# POST: Enables or disables custom DNS servers via UCI + dnsmasq/odhcpd reload.
#
# Data sources:
#   AT+QMAP="MPDN_RULE"          -> determine active NIC (lan vs lan_bind4)
#   dhcp.lan.dhcp_option         -> current custom IPv4 DNS servers (dnsmasq)
#   dhcp.lan.dns                 -> current custom IPv6 DNS servers (odhcpd)
#   /etc/qmanager/dns_mode       -> enabled/disabled state
#
# POST body: { "mode": "enabled"|"disabled", "nic": "lan"|"lan_bind4",
#              "dns1": "...", "dns2": "...", "dns3": "...",
#              "dns1v6": "...", "dns2v6": "..." }
#
# IPv6 DNS is served by odhcpd via RA RDNSS (RFC 6106) and DHCPv6 option 23.
# The dns list MUST target dhcp.lan (not $nic) — odhcpd reads from that section.
# Reload odhcpd with "reload" (SIGHUP), NOT "restart" (restart drops RA briefly).
#
# Endpoint: GET/POST /cgi-bin/quecmanager/network/dns.sh
# Install location: /www/cgi-bin/quecmanager/network/dns.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_dns"
cgi_headers
cgi_handle_options

# --- Helper: determine NIC from MPDN_RULE ------------------------------------
# Parses AT+QMAP="MPDN_RULE" response.
# Fields: "MPDN_rule", index, enabled, pdnIndex, interfaceType, ipType
# If any rule has enabled=1, NIC is "lan_bind4", otherwise "lan".
# Returns 1 (no output) on a transport failure; a modem ERROR reply falls
# through to "lan" as before.
get_nic() {
    mpdn_out=$(qcmd "AT+QMAP=\"MPDN_RULE\"" 2>/dev/null) || return 1
    [ -z "$mpdn_out" ] && return 1
    has_enabled=$(printf '%s' "$mpdn_out" | \
        grep '+QMAP: "MPDN_rule"' | \
        awk -F',' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); if ($3 == "1") print "yes"}' | \
        head -n 1)
    if [ "$has_enabled" = "yes" ]; then
        echo "lan_bind4"
    else
        echo "lan"
    fi
}

# =============================================================================
# GET — Read current DNS configuration
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Reading DNS configuration"

    nic=$(get_nic) || {
        cgi_error "modem_error" "Failed to read the modem LAN binding"
        exit 0
    }
    qlog_debug "Determined NIC: $nic"

    # Read current IPv4 DNS from UCI dhcp_option (format: "6,dns1,dns2,...")
    raw=$(uci get dhcp.lan.dhcp_option 2>/dev/null)
    currentDNS=$(printf '%s' "$raw" | sed 's/^6,//')

    # Read current IPv6 DNS list from dhcp.lan (space-separated in UCI)
    rawv6=$(uci -q get dhcp.lan.dns)
    currentDNS6=$(printf '%s' "$rawv6" | tr ' ' ',')

    # Read mode file
    mode=$(cat /etc/qmanager/dns_mode 2>/dev/null || echo "disabled")

    qlog_info "DNS mode=$mode nic=$nic currentDNS=$currentDNS currentDNS6=$currentDNS6"

    jq -n \
        --arg mode "$mode" \
        --arg currentDNS "$currentDNS" \
        --arg currentDNS6 "$currentDNS6" \
        --arg nic "$nic" \
        '{
            success: true,
            mode: $mode,
            currentDNS: $currentDNS,
            currentDNS6: $currentDNS6,
            nic: $nic
        }'
    exit 0
fi

# =============================================================================
# POST — Enable or disable custom DNS
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    mode=$(printf '%s' "$POST_DATA" | jq -r 'if .mode == null then empty else .mode end')
    nic=$(printf '%s' "$POST_DATA" | jq -r 'if .nic == null then empty else .nic end')
    dns1=$(printf '%s' "$POST_DATA" | jq -r 'if .dns1 == null then empty else .dns1 end')
    dns2=$(printf '%s' "$POST_DATA" | jq -r 'if .dns2 == null then empty else .dns2 end')
    dns3=$(printf '%s' "$POST_DATA" | jq -r 'if .dns3 == null then empty else .dns3 end')
    dns1v6=$(printf '%s' "$POST_DATA" | jq -r 'if .dns1v6 == null then empty else .dns1v6 end')
    dns2v6=$(printf '%s' "$POST_DATA" | jq -r 'if .dns2v6 == null then empty else .dns2v6 end')

    # --- Validate mode ---
    case "$mode" in
        enabled|disabled) ;;
        *)
            cgi_error "invalid_value" "mode must be: enabled or disabled"
            exit 0
            ;;
    esac

    # --- Validate nic ---
    case "$nic" in
        lan|lan_bind4) ;;
        *)
            cgi_error "invalid_value" "nic must be: lan or lan_bind4"
            exit 0
            ;;
    esac

    # --- Validate DNS servers when enabling ---
    if [ "$mode" = "enabled" ]; then
        # At least one address (any family) is required
        if [ -z "$dns1" ] && [ -z "$dns2" ] && [ -z "$dns3" ] && [ -z "$dns1v6" ] && [ -z "$dns2v6" ]; then
            cgi_error "missing_field" "At least one DNS server is required when enabling"
            exit 0
        fi

        # Validate IPv4 address format
        for _dns in "$dns1" "$dns2" "$dns3"; do
            if [ -n "$_dns" ]; then
                case "$_dns" in
                    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
                    *)
                        cgi_error "invalid_dns" "Invalid DNS server address: $_dns"
                        exit 0
                        ;;
                esac
            fi
        done

        # Validate IPv6 address format: must contain ":" and only [0-9a-fA-F:]
        for _dns6 in "$dns1v6" "$dns2v6"; do
            if [ -n "$_dns6" ]; then
                case "$_dns6" in
                    *:*) ;;
                    *)
                        cgi_error "invalid_dns" "Invalid DNS server address: $_dns6"
                        exit 0
                        ;;
                esac
                case "$_dns6" in
                    *[!0-9a-fA-F:]*)
                        cgi_error "invalid_dns" "Invalid DNS server address: $_dns6"
                        exit 0
                        ;;
                esac
            fi
        done
    fi

    # -------------------------------------------------------------------------
    # Path A — Enable custom DNS
    # -------------------------------------------------------------------------
    if [ "$mode" = "enabled" ]; then
        qlog_info "Enabling custom DNS on lan: dns1=$dns1 dns2=$dns2 dns3=$dns3 dns1v6=$dns1v6 dns2v6=$dns2v6"

        # Build comma-separated list of non-empty IPv4 DNS values
        dns_list=$(printf '%s' "$dns1,$dns2,$dns3" | tr ',' '\n' | grep -v '^$' | tr '\n' ',' | sed 's/,$//')

        # Ensure UCI section exists
        uci show dhcp.lan >/dev/null 2>&1 || uci set dhcp.lan=dhcp

        # Apply IPv4: set DHCP option 6 if provided, otherwise clear
        if [ -n "$dns_list" ]; then
            uci set dhcp.lan.dhcp_option="6,$dns_list"
        else
            uci -q delete dhcp.lan.dhcp_option
        fi

        # Set dnsmasq upstream servers so that clients which use the router as
        # their DNS resolver (instead of the DHCP-advertised servers) also get
        # custom DNS.  UCI list 'server' takes precedence over resolv-file.
        uci -q delete dhcp.lan_dns.server
        for _ip in $dns1 $dns2 $dns3; do
            [ -n "$_ip" ] && uci add_list dhcp.lan_dns.server="$_ip"
        done
        for _ip6 in $dns1v6 $dns2v6; do
            [ -n "$_ip6" ] && uci add_list dhcp.lan_dns.server="$_ip6"
        done

        # Apply IPv6: clear any prior list, then rebuild from provided entries
        # Always targets dhcp.lan — odhcpd reads RA/DHCPv6 DNS from that section
        uci -q delete dhcp.lan.dns
        v6_list=""
        for _dns6 in "$dns1v6" "$dns2v6"; do
            if [ -n "$_dns6" ]; then
                uci add_list dhcp.lan.dns="$_dns6"
                if [ -z "$v6_list" ]; then
                    v6_list="$_dns6"
                else
                    v6_list="$v6_list,$_dns6"
                fi
            fi
        done

        uci commit dhcp
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
        # reload (SIGHUP) rather than restart — restart briefly drops RA announcements
        /etc/init.d/odhcpd reload >/dev/null 2>&1

        mkdir -p /etc/qmanager
        echo "enabled" | qm_durable_write /etc/qmanager/dns_mode \n            || qlog_warn "Could not save dns_mode=enabled"

        qlog_info "Custom DNS enabled: IPv4=$dns_list on lan"
        qlog_info "IPv6 DNS list applied on lan: $v6_list"

        jq -n \
            --arg interface "$nic" \
            --arg dns "$dns_list" \
            --arg dns6 "$v6_list" \
            '{success: true, interface: $interface, dns: $dns, dns6: $dns6}'
        exit 0
    fi

    # -------------------------------------------------------------------------
    # Path B — Disable custom DNS (revert to carrier DNS)
    # -------------------------------------------------------------------------
    if [ "$mode" = "disabled" ]; then
        qlog_info "Disabling custom DNS, reverting to carrier DNS on lan"

        # Read carrier IPv4 DNS from resolv.conf.auto
        carrier=$(awk '/^nameserver [0-9.]+/ {print $2}' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null | \
            tr '\n' ',' | sed 's/,$//')

        # Ensure UCI section exists
        uci show dhcp.lan >/dev/null 2>&1 || uci set dhcp.lan=dhcp

        if [ -n "$carrier" ]; then
            uci set dhcp.lan.dhcp_option="6,$carrier"
        else
            uci delete dhcp.lan.dhcp_option 2>/dev/null || true
        fi

        # Remove custom dnsmasq upstream servers — dnsmasq falls back to
        # resolv-file (/tmp/resolv.conf.d/resolv.conf.lan.auto, carrier DNS)
        uci -q delete dhcp.lan_dns.server

        # Clear IPv6 DNS list — clients fall back to router-as-RDNSS (carrier default)
        # Carrier IPv6 is not captured from resolv.conf.auto (IPv4-only source)
        uci -q delete dhcp.lan.dns

        uci commit dhcp
        /etc/init.d/dnsmasq restart >/dev/null 2>&1
        /etc/init.d/odhcpd reload >/dev/null 2>&1

        mkdir -p /etc/qmanager
        echo "disabled" | qm_durable_write /etc/qmanager/dns_mode \n            || qlog_warn "Could not save dns_mode=disabled"

        qlog_info "Carrier DNS restored: $carrier on lan; IPv6 DNS list cleared"

        jq -n \
            --arg interface "lan" \
            --arg dns "$carrier" \
            '{success: true, interface: $interface, dns: $dns, dns6: ""}'
        exit 0
    fi

fi

# --- Method not allowed -------------------------------------------------------
cgi_method_not_allowed
