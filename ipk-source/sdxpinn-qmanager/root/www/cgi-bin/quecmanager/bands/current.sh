#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# current.sh — CGI Endpoint: Get Current Band Lock Configuration
# =============================================================================
# Queries the modem for currently configured (locked) bands via the per-category
# band registers and reads failover state from filesystem flags.
#
# We query lte_band / nsa_nr5g_band / nr5g_band / nrdc_nr5g_band directly (in a
# single appended AT command) rather than ue_capability_band. ue_capability_band
# reports the modem's *advertised capability*, which the firmware filters down to
# the policy-supported set — so a band that was locked but lies OUTSIDE policy
# silently disappears from the readback. The per-category registers report the
# *configured value* verbatim, so locked-but-unsupported bands stay visible.
#
# The response includes colon-delimited band strings for each type plus
# the failover toggle/activation state.
#
# Endpoint: GET /cgi-bin/quecmanager/bands/current.sh
# Response: {
#   "success": true,
#   "current": {
#     "lte_bands": "1:3:7:28:41",
#     "nsa_nr5g_bands": "41:78",
#     "sa_nr5g_bands": "41:78",
#     "nrdc_nr5g_bands": "41:78:257"
#   },
#   "failover": {
#     "enabled": true,
#     "activated": false
#   }
# }
#
# Install location: /www/cgi-bin/quecmanager/bands/current.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_bands_current"
cgi_headers
cgi_handle_options

# --- Configuration -----------------------------------------------------------
FAILOVER_ENABLED_FILE="/etc/qmanager/band_failover_enabled"
FAILOVER_ACTIVATED_FLAG="/tmp/qmanager_band_failover"

# --- Query modem for current band configuration ------------------------------
qlog_info "Querying current band registers (lte/nsa/sa/nrdc)"

result=$(qcmd 'AT+QNWPREFCFG="lte_band";+QNWPREFCFG="nsa_nr5g_band";+QNWPREFCFG="nr5g_band";+QNWPREFCFG="nrdc_nr5g_band"' 2>/dev/null)
rc=$?

if [ $rc -ne 0 ] || [ -z "$result" ]; then
    qlog_error "Failed to query current band registers (rc=$rc)"
    cgi_error "modem_error" "Failed to query current band configuration"
    exit 0
fi

# Check for AT ERROR
case "$result" in
    *ERROR*)
        qlog_error "current band query returned ERROR: $result"
        cgi_error "at_error" "Modem returned error for band query"
        exit 0
        ;;
esac

# --- Parse band lists from response -----------------------------------------
# Response format (one line per appended sub-command):
#   +QNWPREFCFG: "lte_band",1:3:40:41
#   +QNWPREFCFG: "nsa_nr5g_band",13:41:78
#   +QNWPREFCFG: "nr5g_band",41:76
#   +QNWPREFCFG: "nrdc_nr5g_band",1:2:3:5:7:8:...

lte_bands=""
nsa_nr5g_bands=""
sa_nr5g_bands=""
nrdc_nr5g_bands=""

line=$(printf '%s\n' "$result" | grep '+QNWPREFCFG:.*"lte_band"' | head -1)
[ -n "$line" ] && lte_bands=$(printf '%s' "$line" | sed 's/.*"lte_band",//' | tr -d '\r ')

line=$(printf '%s\n' "$result" | grep '+QNWPREFCFG:.*"nsa_nr5g_band"' | head -1)
[ -n "$line" ] && nsa_nr5g_bands=$(printf '%s' "$line" | sed 's/.*"nsa_nr5g_band",//' | tr -d '\r ')

# Exclude nsa_ and nrdc_ lines that also contain "nr5g_band"
line=$(printf '%s\n' "$result" | grep '+QNWPREFCFG:.*"nr5g_band"' | grep -v 'nsa_' | grep -v 'nrdc_' | head -1)
[ -n "$line" ] && sa_nr5g_bands=$(printf '%s' "$line" | sed 's/.*"nr5g_band",//' | tr -d '\r ')

line=$(printf '%s\n' "$result" | grep '+QNWPREFCFG:.*"nrdc_nr5g_band"' | head -1)
[ -n "$line" ] && nrdc_nr5g_bands=$(printf '%s' "$line" | sed 's/.*"nrdc_nr5g_band",//' | tr -d '\r ')

qlog_debug "Current bands: LTE=$lte_bands NSA=$nsa_nr5g_bands SA=$sa_nr5g_bands NRDC=$nrdc_nr5g_bands"

# --- Read failover state -----------------------------------------------------
failover_enabled="false"
if [ -f "$FAILOVER_ENABLED_FILE" ]; then
    val=$(cat "$FAILOVER_ENABLED_FILE" 2>/dev/null | tr -d ' \n\r')
    [ "$val" = "1" ] && failover_enabled="true"
fi

failover_activated="false"
if [ -f "$FAILOVER_ACTIVATED_FLAG" ]; then
    failover_activated="true"
fi

# --- Response ----------------------------------------------------------------
jq -n --arg lte "$lte_bands" --arg nsa "$nsa_nr5g_bands" --arg sa "$sa_nr5g_bands" \
    --arg nrdc "$nrdc_nr5g_bands" \
    --argjson fe "$failover_enabled" --argjson fa "$failover_activated" \
    '{"success":true,"current":{"lte_bands":$lte,"nsa_nr5g_bands":$nsa,"sa_nr5g_bands":$sa,"nrdc_nr5g_bands":$nrdc},"failover":{"enabled":$fe,"activated":$fa}}'
