#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh
# =============================================================================
# lock.sh — CGI Endpoint: Apply Band Lock
# =============================================================================
# Locks bands for a single category (lte, nsa_nr5g, sa_nr5g, or nrdc_nr5g).
# Per-card operation — each band card sends its own independent lock request.
#
# NR-DC IS lockable: writes to nrdc_nr5g_band were verified on-device to stick
# verbatim (no coercion, including bands outside the policy set), so it uses the
# same apply path as the other categories.
#
# POST body:
#   {"band_type":"lte","bands":"1:3:7:28"}
#   {"band_type":"nsa_nr5g","bands":"41:78"}
#   {"band_type":"sa_nr5g","bands":"41:78"}
#   {"band_type":"nrdc_nr5g","bands":"41:78:257"}
#
# On success, clears any previous failover activation flag and spawns the
# failover watcher (if failover is enabled) to monitor connectivity.
#
# Endpoint: POST /cgi-bin/quecmanager/bands/lock.sh
# Install location: /www/cgi-bin/quecmanager/bands/lock.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_bands_lock"
cgi_headers
cgi_handle_options

# --- Configuration -----------------------------------------------------------
FAILOVER_ENABLED_FILE="/etc/qmanager/band_failover_enabled"
FAILOVER_ACTIVATED_FLAG="/tmp/qmanager_band_failover"
FAILOVER_PID_FILE="/tmp/qmanager_band_failover.pid"
FAILOVER_SCRIPT="/usr/bin/qmanager_band_failover"

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Read POST body ----------------------------------------------------------
cgi_read_post

# --- Parse JSON fields -------------------------------------------------------
BAND_TYPE=$(printf '%s' "$POST_DATA" | jq -r 'if .band_type == null then empty else .band_type end')
BANDS=$(printf '%s' "$POST_DATA" | jq -r 'if .bands == null then empty else .bands end')

# --- Validate inputs ---------------------------------------------------------
if [ -z "$BAND_TYPE" ]; then
    cgi_error "no_band_type" "Missing band_type field"
    exit 0
fi

if [ -z "$BANDS" ]; then
    cgi_error "no_bands" "Missing bands field"
    exit 0
fi

# Validate band_type is one of the allowed values
AT_PARAM=""
case "$BAND_TYPE" in
    lte)        AT_PARAM="lte_band" ;;
    nsa_nr5g)   AT_PARAM="nsa_nr5g_band" ;;
    sa_nr5g)    AT_PARAM="nr5g_band" ;;
    nrdc_nr5g)  AT_PARAM="nrdc_nr5g_band" ;;
    *)
        cgi_error "invalid_band_type" "band_type must be lte, nsa_nr5g, sa_nr5g, or nrdc_nr5g"
        exit 0
        ;;
esac

# Validate bands format: must be colon-delimited numbers only
cleaned=$(echo "$BANDS" | tr -d '0-9:')
if [ -n "$cleaned" ]; then
    cgi_error "invalid_bands" "bands must be colon-delimited numbers (e.g. 1:3:7:28)"
    exit 0
fi

qlog_info "Band lock request: type=$BAND_TYPE param=$AT_PARAM bands=$BANDS"

# --- Send AT command ---------------------------------------------------------
AT_CMD="AT+QNWPREFCFG=\"${AT_PARAM}\",${BANDS}"

result=$(qcmd "$AT_CMD" 2>/dev/null)
rc=$?

if [ $rc -ne 0 ] || [ -z "$result" ]; then
    qlog_error "Band lock failed (rc=$rc): $AT_CMD"
    cgi_error "modem_error" "Failed to send band lock command"
    exit 0
fi

case "$result" in
    *ERROR*)
        qlog_error "Band lock AT ERROR: $AT_CMD -> $result"
        cgi_error "at_error" "Modem rejected band lock command"
        exit 0
        ;;
esac

qlog_info "Band lock applied: $AT_PARAM=$BANDS"

# --- Force an early poller Tier-2 refresh so the UI reflects the new band
#     registration within ~2s instead of the next ~30s tier boundary ---
sleep 2
touch /tmp/qmanager_force_tier2

# --- Clear failover activation flag (new lock supersedes previous failover) --
rm -f "$FAILOVER_ACTIVATED_FLAG"

# --- Spawn failover watcher if enabled ---------------------------------------
failover_armed="false"

failover_enabled="false"
if [ -f "$FAILOVER_ENABLED_FILE" ]; then
    val=$(cat "$FAILOVER_ENABLED_FILE" 2>/dev/null | tr -d ' \n\r')
    [ "$val" = "1" ] && failover_enabled="true"
fi

if [ "$failover_enabled" = "true" ] && [ -x "$FAILOVER_SCRIPT" ]; then
    # Kill any existing watcher (latest lock is the one we monitor)
    if [ -f "$FAILOVER_PID_FILE" ]; then
        old_pid=$(qm_read_pid "$FAILOVER_PID_FILE" qmanager_band_failover)
        if [ -n "$old_pid" ]; then
            kill "$old_pid" 2>/dev/null
            qlog_debug "Killed previous failover watcher (PID=$old_pid)"
        fi
        rm -f "$FAILOVER_PID_FILE"
    fi

    # Spawn new watcher (detached via double-fork to escape CGI process group)
    # The & is INSIDE the outer (), making the script a grandchild reparented to init
    ( "$FAILOVER_SCRIPT" </dev/null >/dev/null 2>&1 & )
    qlog_info "Failover watcher spawned"
    failover_armed="true"
fi

# --- Response ----------------------------------------------------------------
jq -n --arg bt "$BAND_TYPE" --arg b "$BANDS" --argjson fa "$failover_armed" \
    '{"success":true,"band_type":$bt,"bands":$b,"failover_armed":$fa}'
