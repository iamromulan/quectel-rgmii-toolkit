#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/cgi_at.sh
# =============================================================================
# status.sh — CGI Endpoint: Get Frequency Lock Status
# =============================================================================
# Returns current frequency lock state from the modem (AT+QNWCFG queries)
# and tower lock state (AT+QNWLOCK queries) for mutual exclusion gating.
#
# Queries 4 AT commands (with sleep between each):
#   1. AT+QNWCFG="lte_earfcn_lock"   — LTE frequency lock state
#   2. AT+QNWCFG="nr5g_earfcn_lock"  — NR5G frequency lock state
#   3. AT+QNWLOCK="common/4g"         — LTE tower lock (for mutual exclusion)
#   4. AT+QNWLOCK="common/5g"         — NR tower lock (for mutual exclusion)
#
# Endpoint: GET /cgi-bin/quecmanager/frequency/status.sh
# Install location: /www/cgi-bin/quecmanager/frequency/status.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_freq_status"
cgi_headers
cgi_handle_options

# --- Load tower lock library (for tower_read_lte_lock / tower_read_nr_lock) --
if [ -f /usr/lib/qmanager/tower_lock_mgr.sh ]; then
    . /usr/lib/qmanager/tower_lock_mgr.sh
else
    cgi_error "internal_error" "tower lock library unavailable"
    exit 0
fi

# =============================================================================
# Compound AT: fetch both frequency lock states in one call
# =============================================================================
qlog_debug "Querying frequency lock states"
# Transport failure (rc 1) is an error, not "no locks"; a modem ERROR (rc 2)
# keeps the empty-parse behaviour.
at_exec 'AT+QNWCFG="lte_earfcn_lock";+QNWCFG="nr5g_earfcn_lock"'
if [ $? -eq 1 ]; then
    cgi_error "modem_error" "Failed to read frequency lock status"
    exit 0
fi
raw="$AT_RAW"

# --- LTE frequency lock ---
lte_freq_locked="false"
lte_freq_entries_json="[]"

line=$(printf '%s\n' "$raw" | grep '+QNWCFG:.*"lte_earfcn_lock"' | head -1 | tr -d '\r')
if [ -n "$line" ]; then
    params=$(printf '%s' "$line" | sed 's/.*"lte_earfcn_lock",//' | tr -d ' ')
    count=$(printf '%s' "$params" | cut -d',' -f1)

    if [ "$count" -gt 0 ] 2>/dev/null; then
        lte_freq_locked="true"
        earfcn_str=$(printf '%s' "$params" | cut -d',' -f2)
        # Split colon-separated EARFCNs into JSON array
        lte_freq_entries_json="["
        first="true"
        OLD_IFS="$IFS"
        IFS=":"
        for earfcn in $earfcn_str; do
            [ -z "$earfcn" ] && continue
            if [ "$first" = "true" ]; then
                first="false"
            else
                lte_freq_entries_json="${lte_freq_entries_json},"
            fi
            lte_freq_entries_json="${lte_freq_entries_json}{\"earfcn\":$earfcn}"
        done
        IFS="$OLD_IFS"
        lte_freq_entries_json="${lte_freq_entries_json}]"
    fi
fi

# --- NR5G frequency lock ---
nr_freq_locked="false"
nr_freq_entries_json="[]"

line=$(printf '%s\n' "$raw" | grep '+QNWCFG:.*"nr5g_earfcn_lock"' | head -1 | tr -d '\r')
if [ -n "$line" ]; then
    params=$(printf '%s' "$line" | sed 's/.*"nr5g_earfcn_lock",//' | tr -d ' ')
    count=$(printf '%s' "$params" | cut -d',' -f1)

    if [ "$count" -gt 0 ] 2>/dev/null; then
        nr_freq_locked="true"
        arfcn_str=$(printf '%s' "$params" | cut -d',' -f2)
        # Parse alternating EARFCN:SCS pairs
        nr_freq_entries_json="["
        first="true"
        set -- $(printf '%s' "$arfcn_str" | tr ':' ' ')
        while [ $# -ge 2 ]; do
            if [ "$first" = "true" ]; then
                first="false"
            else
                nr_freq_entries_json="${nr_freq_entries_json},"
            fi
            nr_freq_entries_json="${nr_freq_entries_json}{\"arfcn\":$1,\"scs\":$2}"
            shift 2
        done
        nr_freq_entries_json="${nr_freq_entries_json}]"
    fi
fi

# =============================================================================
# Query tower lock state (for mutual exclusion gating)
# =============================================================================
# Tri-state on the wire: true, false, or the JSON literal null when the tower
# state could not be read. A failed read is not "no tower lock": lock.sh refuses
# a frequency lock it cannot gate, and the page blocks on null with its own copy.
qlog_debug "Checking tower lock state for gating"
lte_tower_state=$(tower_read_lte_lock 2>/dev/null)
lte_tower_rc=$?
if [ "$lte_tower_rc" -ne 0 ] || [ -z "$lte_tower_state" ] || [ "$lte_tower_state" = "error" ]; then
    tower_lock_lte="null"
else
    tower_lock_lte="false"
    case "$lte_tower_state" in
        locked*) tower_lock_lte="true" ;;
    esac
fi

sleep 0.1

nr_tower_state=$(tower_read_nr_lock 2>/dev/null)
nr_tower_rc=$?
if [ "$nr_tower_rc" -ne 0 ] || [ -z "$nr_tower_state" ] || [ "$nr_tower_state" = "error" ]; then
    tower_lock_nr="null"
else
    tower_lock_nr="false"
    case "$nr_tower_state" in
        locked*) tower_lock_nr="true" ;;
    esac
fi

# =============================================================================
# Build response JSON
# =============================================================================
response_json=$(jq -n \
    --argjson lte_locked "$lte_freq_locked" \
    --argjson lte_entries "$lte_freq_entries_json" \
    --argjson nr_locked "$nr_freq_locked" \
    --argjson nr_entries "$nr_freq_entries_json" \
    --argjson tower_lte "$tower_lock_lte" \
    --argjson tower_nr "$tower_lock_nr" \
    '{
        success: true,
        modem_state: {
            lte_locked: $lte_locked,
            lte_entries: $lte_entries,
            nr_locked: $nr_locked,
            nr_entries: $nr_entries,
            tower_lock_lte_active: $tower_lte,
            tower_lock_nr_active: $tower_nr
        }
    }' 2>/dev/null)

if [ -n "$response_json" ]; then
    printf '%s\n' "$response_json"
else
    # jq failed: report the tower state as unread (null), never as "unlocked".
    qlog_error "Failed to build status JSON with jq, sending fallback"
    printf '{"success":true,"modem_state":{"lte_locked":false,"lte_entries":[],"nr_locked":false,"nr_entries":[],"tower_lock_lte_active":null,"tower_lock_nr_active":null}}\n'
fi
