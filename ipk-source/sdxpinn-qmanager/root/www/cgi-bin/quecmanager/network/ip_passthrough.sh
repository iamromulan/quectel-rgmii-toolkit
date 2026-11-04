#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/cgi_at.sh
# =============================================================================
# ip_passthrough.sh — CGI Endpoint: IP Passthrough (IPPT) Settings (GET + POST)
# =============================================================================
# GET:  Reads current passthrough mode (MPDN_RULE), NAT mode (IPPT_NAT),
#       USB modem protocol (QCFG usbnet), and DNS offloading (DHCPV4DNS).
# POST: Validates, applies all AT commands, then immediately reboots.
#       No separate reboot action — apply and reboot happen in one shot.
#
# AT commands used (GET):
#   AT+QMAP="MPDN_RULE"   -> Passthrough mode + IPPT_info for rule 0
#   AT+QMAP="IPPT_NAT"    -> NAT mode (0=WithoutNAT, 1=WithNAT)
#   AT+QCFG="usbnet"      -> USB modem protocol (0=rmnet,1=ecm,2=mbim,3=rndis)
#   AT+QMAP="DHCPV4DNS"   -> DNS offloading status (enable/disable)
#
# AT commands used (POST, action=apply):
#   AT+QMAP="MPDN_rule",0             -> Disable passthrough (rule 0 reset)
#   AT+QMAPWAC=1                      -> WAC reset (only when disabling)
#   AT+QMAP="MPDN_rule",0,1,0,1,1,"<mac>" -> Enable ETH passthrough
#   AT+QMAP="MPDN_rule",0,1,0,3,1,"<mac>" -> Enable USB passthrough
#   AT+QMAP="IPPT_NAT",<0|1>         -> Set NAT mode
#   AT+QCFG="usbnet",<0-3>           -> Set USB modem protocol
#   AT+QMAP="DHCPV4DNS","enable|disable" -> Set DNS offloading
#
# MPDN_RULE field layout (comma-separated after +QMAP: prefix):
#   $1="MPDN_rule"  $2=rule_num  $3=profileID  $4=VLAN_ID
#   $5=IPPT_mode    $6=auto_connect  [$7=IPPT_info (MAC/hostname, quoted)]
#
# IPPT_mode values: 0=disabled, 1=ETH, 2=WiFi, 3=USB-ECM/RNDIS, 4=Any
#
# Endpoint: GET/POST /cgi-bin/quecmanager/network/ip_passthrough.sh
# Install location: /www/cgi-bin/quecmanager/network/ip_passthrough.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_ip_passthrough"
cgi_headers
cgi_handle_options

# --- Configuration -----------------------------------------------------------
CMD_GAP=0.2
IPPT_CONFIG="/etc/qmanager/ippt_config.json"
POLLER_CACHE="/tmp/qmanager_status.json"

# --- Helper: Validate MAC address (XX:XX:XX:XX:XX:XX) -----------------------
validate_mac() {
    case "$1" in
        [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# GET — Fetch current IP Passthrough settings
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Fetching IP Passthrough settings"

    # --- 1-4. Read settings: config file (primary) → poller cache (fallback) ---
    # Config file is written by POST and is the authoritative source.
    # Poller cache is populated at boot from AT commands.
    if [ -f "$IPPT_CONFIG" ]; then
        passthrough_mode=$(jq -r '.mode // "disabled"' "$IPPT_CONFIG" 2>/dev/null)
        target_mac=$(jq -r '.mac // ""' "$IPPT_CONFIG" 2>/dev/null)
        ippt_nat=$(jq -r '.nat // "1"' "$IPPT_CONFIG" 2>/dev/null)
        usb_mode=$(jq -r '.usb_mode // "1"' "$IPPT_CONFIG" 2>/dev/null)
        dns_proxy=$(jq -r '.dns_proxy // "disabled"' "$IPPT_CONFIG" 2>/dev/null)
        qlog_debug "config: mode=$passthrough_mode nat=$ippt_nat usb=$usb_mode dns=$dns_proxy"
    else
        passthrough_mode=$(jq -r '.device.ippt_mode // "disabled"' "$POLLER_CACHE" 2>/dev/null)
        target_mac=$(jq -r '.device.ippt_mac // ""' "$POLLER_CACHE" 2>/dev/null)
        ippt_nat=$(jq -r '.device.ippt_nat // "1"' "$POLLER_CACHE" 2>/dev/null)
        usb_mode=$(jq -r '.device.ippt_usbnet // "1"' "$POLLER_CACHE" 2>/dev/null)
        dns_proxy=$(jq -r '.device.ippt_dhcpv4dns // "disabled"' "$POLLER_CACHE" 2>/dev/null)
        qlog_debug "cache fallback: mode=$passthrough_mode nat=$ippt_nat usb=$usb_mode dns=$dns_proxy"
    fi

    # Validate values (guard against corrupted source)
    case "$passthrough_mode" in disabled|eth|usb) ;; *) passthrough_mode="disabled" ;; esac
    case "$ippt_nat" in 0|1) ;; *) ippt_nat="1" ;; esac
    case "$usb_mode" in 0|1|2|3) ;; *) usb_mode="1" ;; esac
    case "$dns_proxy" in enabled|disabled) ;; *) dns_proxy="disabled" ;; esac

    qlog_info "GET: mode=$passthrough_mode nat=$ippt_nat usb=$usb_mode dns=$dns_proxy"

    jq -n \
        --arg mode "$passthrough_mode" \
        --arg mac "$target_mac" \
        --arg nat "$ippt_nat" \
        --arg usb "$usb_mode" \
        --arg dns "$dns_proxy" \
        '{
            success: true,
            passthrough_mode: $mode,
            target_mac: $mac,
            ippt_nat: $nat,
            usb_mode: $usb,
            dns_proxy: $dns
        }'
    exit 0
fi

# =============================================================================
# POST — Apply all settings and immediately reboot
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    # --- Guard: Verizon profile lock -----------------------------------------
    [ -n "$_PROFILE_MGR_LOADED" ] || . /usr/lib/qmanager/profile_mgr.sh
    _ippt_active=$(get_active_profile)
    if [ -n "$_ippt_active" ] && [ -f "$PROFILE_DIR/${_ippt_active}.json" ]; then
        _ippt_mno=$(jq -r '.mno // empty' "$PROFILE_DIR/${_ippt_active}.json" 2>/dev/null)
        if [ "$_ippt_mno" = "Verizon" ]; then
            cgi_error "ip_passthrough_locked_by_verizon_profile" "IP Passthrough is managed by the active Verizon profile"
            exit 0
        fi
    fi

    # --- Extract action ---
    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty')

    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: apply — Write all settings then reboot immediately
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "apply" ]; then
        PASSTHROUGH_MODE=$(printf '%s' "$POST_DATA" | jq -r '.passthrough_mode // empty')
        TARGET_MAC=$(printf '%s' "$POST_DATA" | jq -r '.target_mac // empty')
        IPPT_NAT=$(printf '%s' "$POST_DATA" | jq -r '.ippt_nat // empty')
        USB_MODE=$(printf '%s' "$POST_DATA" | jq -r '.usb_mode // empty')
        DNS_PROXY=$(printf '%s' "$POST_DATA" | jq -r '.dns_proxy // empty')

        qlog_info "Apply: mode=$PASSTHROUGH_MODE mac=$TARGET_MAC nat=$IPPT_NAT usb=$USB_MODE dns=$DNS_PROXY"

        # --- Validate passthrough_mode ---
        case "$PASSTHROUGH_MODE" in
            disabled|eth|usb) ;;
            *)
                cgi_error "invalid_passthrough_mode" "passthrough_mode must be disabled, eth, or usb"
                exit 0
                ;;
        esac

        # --- Validate MAC (required for eth/usb) ---
        if [ "$PASSTHROUGH_MODE" != "disabled" ]; then
            if [ -z "$TARGET_MAC" ]; then
                cgi_error "missing_target_mac" "target_mac is required when passthrough_mode is eth or usb"
                exit 0
            fi
            if ! validate_mac "$TARGET_MAC"; then
                cgi_error "invalid_target_mac" "target_mac must be in XX:XX:XX:XX:XX:XX format"
                exit 0
            fi
        fi

        # --- Validate ippt_nat ---
        case "$IPPT_NAT" in
            0|1) ;;
            *)
                cgi_error "invalid_ippt_nat" "ippt_nat must be 0 (WithoutNAT) or 1 (WithNAT)"
                exit 0
                ;;
        esac

        # --- Validate usb_mode ---
        case "$USB_MODE" in
            0|1|2|3) ;;
            *)
                cgi_error "invalid_usb_mode" "usb_mode must be 0, 1, 2, or 3"
                exit 0
                ;;
        esac

        # --- Validate dns_proxy ---
        case "$DNS_PROXY" in
            enabled|disabled) ;;
            *)
                cgi_error "invalid_dns_proxy" "dns_proxy must be enabled or disabled"
                exit 0
                ;;
        esac

        # --- Step 1: Apply MPDN_RULE passthrough setting ---
        case "$PASSTHROUGH_MODE" in
            disabled)
                at_exec 'AT+QMAP="MPDN_rule",0'
                case $? in
                    1) cgi_error "modem_error" "Modem did not answer the MPDN_rule reset"; exit 0 ;;
                    2)
                        qlog_error "MPDN_rule disable failed: $AT_RAW"
                        cgi_error "mpdn_rule_failed" "Failed to reset MPDN_rule"
                        exit 0
                        ;;
                esac
                sleep "$CMD_GAP"
                # WAC reset — required when disabling passthrough
                at_exec 'AT+QMAPWAC=1' || qlog_warn "QMAPWAC=1 failed (non-fatal): $AT_RAW"
                ;;
            eth)
                at_exec "AT+QMAP=\"MPDN_rule\",0,1,0,1,1,\"${TARGET_MAC}\""
                case $? in
                    1) cgi_error "modem_error" "Modem did not answer the MPDN_rule write"; exit 0 ;;
                    2)
                        qlog_error "MPDN_rule ETH failed: $AT_RAW"
                        cgi_error "mpdn_rule_failed" "Failed to set ETH passthrough rule"
                        exit 0
                        ;;
                esac
                ;;
            usb)
                at_exec "AT+QMAP=\"MPDN_rule\",0,1,0,3,1,\"${TARGET_MAC}\""
                case $? in
                    1) cgi_error "modem_error" "Modem did not answer the MPDN_rule write"; exit 0 ;;
                    2)
                        qlog_error "MPDN_rule USB failed: $AT_RAW"
                        cgi_error "mpdn_rule_failed" "Failed to set USB passthrough rule"
                        exit 0
                        ;;
                esac
                ;;
        esac

        sleep "$CMD_GAP"

        # --- Step 2: Apply IPPT_NAT mode ---
        at_exec "AT+QMAP=\"IPPT_NAT\",${IPPT_NAT}"
        case $? in
            1) cgi_error "modem_error" "Modem did not answer the IPPT_NAT write"; exit 0 ;;
            2)
                qlog_error "IPPT_NAT failed: $AT_RAW"
                cgi_error "ippt_nat_failed" "Failed to set IPPT NAT mode"
                exit 0
                ;;
        esac

        sleep "$CMD_GAP"

        # --- Step 3: Apply USB modem protocol ---
        at_exec "AT+QCFG=\"usbnet\",${USB_MODE}"
        case $? in
            1) cgi_error "modem_error" "Modem did not answer the QCFG usbnet write"; exit 0 ;;
            2)
                qlog_error "QCFG usbnet failed: $AT_RAW"
                cgi_error "usbnet_failed" "Failed to set USB modem protocol"
                exit 0
                ;;
        esac

        sleep "$CMD_GAP"

        # --- Step 4: Apply DNS offloading ---
        case "$DNS_PROXY" in
            enabled)  dns_cmd='AT+QMAP="DHCPV4DNS","enable"' ;;
            disabled) dns_cmd='AT+QMAP="DHCPV4DNS","disable"' ;;
        esac

        at_exec "$dns_cmd"
        case $? in
            1) cgi_error "modem_error" "Modem did not answer the DHCPV4DNS write"; exit 0 ;;
            2)
                qlog_error "DHCPV4DNS failed: $AT_RAW"
                cgi_error "dhcpv4dns_failed" "Failed to set DNS offloading"
                exit 0
                ;;
        esac

        qlog_info "All settings applied — saving config and rebooting"

        # --- Step 5: Persist settings to config file (atomic: temp + mv) ---
        # This is the authoritative source read back by GET after reboot.
        mkdir -p /etc/qmanager
        IPPT_TMP="${IPPT_CONFIG}.tmp"
        if jq -n \
            --arg mode "$PASSTHROUGH_MODE" \
            --arg mac  "$TARGET_MAC" \
            --arg nat  "$IPPT_NAT" \
            --arg usb  "$USB_MODE" \
            --arg dns  "$DNS_PROXY" \
            '{mode:$mode, mac:$mac, nat:$nat, usb_mode:$usb, dns_proxy:$dns}' \
            > "$IPPT_TMP" 2>/dev/null; then
            mv "$IPPT_TMP" "$IPPT_CONFIG" 2>/dev/null || { rm -f "$IPPT_TMP"; qlog_warn "Failed to save ippt_config.json"; }
        else
            rm -f "$IPPT_TMP"
            qlog_warn "Failed to write ippt_config.json (non-fatal)"
        fi

        # Return response BEFORE rebooting so HTTP is flushed
        cgi_success

        # Drop a planned-reboot breadcrumb (synchronously, before the async
        # reboot) so the next boot classifies this IPPT apply as a user reboot.
        record_planned_reboot "user"

        # Reboot with short delay to ensure response is sent
        ( ( sleep 2; sync; reboot ) </dev/null >/dev/null 2>&1 & )
        exit 0
    fi

    # --- Unknown action ---
    cgi_error "invalid_action" "action must be apply"
    exit 0
fi

# --- Method not allowed -------------------------------------------------------
cgi_method_not_allowed
