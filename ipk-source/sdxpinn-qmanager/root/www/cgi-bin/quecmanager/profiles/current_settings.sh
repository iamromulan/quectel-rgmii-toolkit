#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/cgi_at.sh
. /usr/lib/qmanager/sim_db.sh
[ -f /usr/lib/qmanager/data_cid.sh ] && . /usr/lib/qmanager/data_cid.sh
# =============================================================================
# current_settings.sh — CGI Endpoint: Current Modem Settings
# =============================================================================
# Queries the modem for current APN, IMEI, and ICCID.
# Used to pre-fill the profile creation form with live modem values.
#
# Uses compound AT syntax (semicolon-separated) to fetch all data in
# a single modem round-trip for fast page load.
#
# Called ONCE when the user opens the profile form, not on a timer.
#
# NOTE: Band locking and network mode queries have been removed.
# They will be owned by the Connection Scenarios feature.
#
# Endpoint: GET /cgi-bin/quecmanager/profiles/current_settings.sh
# Response: CurrentModemSettings JSON (see types/sim-profile.ts)
#
# Install location: /www/cgi-bin/quecmanager/profiles/current_settings.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_current_settings"
cgi_headers
cgi_handle_options

# --- Configuration -----------------------------------------------------------
CMD_GAP=0.2   # Gap between AT commands (seconds) — kept for POST if needed

qlog_info "Querying current modem settings for profile form"

# --- Compound AT: fetch all settings in one call ---
# Transport failure (rc 1) is an error, not an empty form; a modem ERROR (rc 2)
# keeps the partial-parse behaviour.
at_exec 'AT+CGDCONT?;+CGACT?;+CGSN;+QCCID;+CGPADDR'
if [ $? -eq 1 ]; then
    cgi_error "modem_error" "Failed to read current modem settings"
    exit 0
fi
raw="$AT_RAW"

# --- 1. APN profiles from +CGDCONT: lines ---
cgdcont_lines=$(printf '%s\n' "$raw" | grep '+CGDCONT:')
apn_array=$(parse_cgdcont "$cgdcont_lines")

# --- 2. Current IMEI — bare 15-digit line from AT+CGSN ---
current_imei=$(printf '%s\n' "$raw" | tr -d '\r' | grep -x '[0-9]\{15\}' | head -1)

# --- 3. Current ICCID from +QCCID: line ---
# Use the canonical apply-time pipeline (keep the raw string) then strip only
# the trailing BCD pad F via iccid_canonicalize, so a profile saved from this
# form stores the same value apply-time compares against. The old digits-only
# extractor silently dropped the pad, diverging from every apply-time reader.
current_iccid=$(iccid_canonicalize "$(printf '%s\n' "$raw" | grep '+QCCID:' | head -1 | sed 's/+QCCID: //g')")

# --- 4. Active CID (CGPADDR confirmed against the kernel route; data_cid.sh) ---
active_cid=""
if command -v qm_detect_data_cid >/dev/null 2>&1; then
    qm_detect_data_cid "$(printf '%s\n' "$raw" | tr -d '\r')"
    active_cid="$QM_DATA_CID"
fi
case "$active_cid" in ''|*[!0-9]*) active_cid="1" ;; esac

# =============================================================================
# Build and output response JSON
# =============================================================================

jq -n --argjson apns "$apn_array" \
    --arg imei "$current_imei" \
    --arg iccid "$current_iccid" \
    --arg active_cid "$active_cid" \
    '{
        "apn_profiles": $apns,
        "imei": $imei,
        "iccid": $iccid,
        "active_cid": ($active_cid | tonumber)
    }'

qlog_info "Current settings query complete (active_cid=$active_cid)"
