#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/cgi_at.sh
# =============================================================================
# network_priority.sh — CGI Endpoint: RAT Acquisition Order (GET + POST)
# =============================================================================
# GET:  Reads current RAT acquisition order via AT+QNWPREFCFG="rat_acq_order"
# POST: Sets new RAT acquisition order
#
# AT commands:
#   AT+QNWPREFCFG="rat_acq_order"              -> Current order (e.g. NR5G:LTE)
#   AT+QNWPREFCFG="rat_acq_order",<order>      -> Set order (e.g. LTE:NR5G)
#
# Endpoint: GET/POST /cgi-bin/quecmanager/cellular/network_priority.sh
# Install location: /www/cgi-bin/quecmanager/cellular/network_priority.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_net_prio"
cgi_headers
cgi_handle_options

# =============================================================================
# GET — Fetch current RAT acquisition order
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Fetching RAT acquisition order"

    resp=$(run_at 'AT+QNWPREFCFG="rat_acq_order"')

    if [ -z "$resp" ]; then
        cgi_error "at_failed" "Failed to query rat_acq_order"
        exit 0
    fi

    # +QNWPREFCFG: "rat_acq_order",NR5G:LTE:WCDMA
    order=$(printf '%s' "$resp" | awk -F',' '
        /\+QNWPREFCFG:.*"rat_acq_order"/ {
            val = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (val != "") print val
        }
    ')

    if [ -z "$order" ]; then
        cgi_error "parse_failed" "Could not parse rat_acq_order response"
        exit 0
    fi

    qlog_info "RAT acquisition order: $order"

    jq -n --arg order "$order" '{success: true, order: $order}'
    exit 0
fi

# =============================================================================
# POST — Set RAT acquisition order
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    ORDER=$(printf '%s' "$POST_DATA" | jq -r '.order // empty')

    if [ -z "$ORDER" ]; then
        cgi_error "missing_order" "order field is required"
        exit 0
    fi

    # Validate: only allow known RAT names separated by colons
    case "$ORDER" in
        *[!A-Z0-9:]*)
            cgi_error "invalid_order" "order must contain only RAT names separated by colons"
            exit 0
            ;;
    esac

    qlog_info "Setting RAT acquisition order: $ORDER"

    at_exec "AT+QNWPREFCFG=\"rat_acq_order\",$ORDER"
    case $? in
        1) cgi_error "modem_error" "Modem did not answer the RAT order write"; exit 0 ;;
        2)
            qlog_error "Failed to set rat_acq_order: $AT_RAW"
            cgi_error "at_failed" "AT+QNWPREFCFG returned ERROR"
            exit 0
            ;;
    esac

    qlog_info "RAT acquisition order set to: $ORDER"
    cgi_success
    exit 0
fi

# --- Method not allowed -------------------------------------------------------
cgi_method_not_allowed
