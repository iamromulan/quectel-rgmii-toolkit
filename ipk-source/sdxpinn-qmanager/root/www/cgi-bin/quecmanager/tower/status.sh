#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# status.sh — CGI Endpoint: Get Tower Lock Status
# =============================================================================
# Returns current tower lock state from the modem, config from file,
# and failover state from flag files.
#
# Queries 3 AT commands (sip-don't-gulp: sleep between each):
#   1. AT+QNWLOCK="common/4g"   — LTE lock state
#   2. AT+QNWLOCK="common/5g"   — NR-SA lock state
#   3. AT+QNWLOCK="save_ctrl"   — Persistence state
#
# Plus reads config file and failover flags (no modem contact).
# Uses jq for ALL JSON construction — guaranteed valid output.
#
# Endpoint: GET /cgi-bin/quecmanager/tower/status.sh
# Install location: /www/cgi-bin/quecmanager/tower/status.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_tower_status"
cgi_headers
cgi_handle_options

# --- Load library ------------------------------------------------------------
if [ -f /usr/lib/qmanager/tower_lock_mgr.sh ]; then
    . /usr/lib/qmanager/tower_lock_mgr.sh
else
    cgi_error "internal_error" "tower lock library unavailable"
    exit 0
fi

# --- Ensure config exists ----------------------------------------------------
tower_config_init

# --- Query LTE lock state ----------------------------------------------------
# Each reader's rc becomes a *_read_ok flag, so a failed read is reported as
# unknown instead of a confident "unlocked" / "disabled". Clients treat an
# absent flag as true (older backends emit none).
qlog_debug "Querying LTE lock state"
lte_read_ok="true"
lte_state=$(tower_read_lte_lock) || lte_read_ok="false"
sleep 0.1

# --- Query NR-SA lock state --------------------------------------------------
qlog_debug "Querying NR-SA lock state"
nr_read_ok="true"
nr_state=$(tower_read_nr_lock) || nr_read_ok="false"
sleep 0.1

# --- Query persist state -----------------------------------------------------
qlog_debug "Querying persist state"
persist_read_ok="true"
persist_state=$(tower_read_persist) || persist_read_ok="false"

# --- Parse LTE lock state into JSON ------------------------------------------
lte_locked="false"
lte_cells_json="[]"

case "$lte_state" in
    locked*)
        lte_locked="true"
        # Parse: "locked <num> <earfcn1> <pci1> [<earfcn2> <pci2> ...]"
        set -- $lte_state  # word split
        shift  # remove "locked"
        shift  # remove num_cells
        lte_cells_json="["
        local_first="true"
        while [ $# -ge 2 ]; do
            if [ "$local_first" = "true" ]; then
                local_first="false"
            else
                lte_cells_json="${lte_cells_json},"
            fi
            lte_cells_json="${lte_cells_json}{\"earfcn\":$1,\"pci\":$2}"
            shift 2
        done
        lte_cells_json="${lte_cells_json}]"
        ;;
    error)
        qlog_warn "Failed to read LTE lock state"
        ;;
esac

# --- Parse NR-SA lock state into JSON ----------------------------------------
nr_locked="false"
nr_cell_json="null"

case "$nr_state" in
    locked*)
        nr_locked="true"
        # Parse: "locked <pci> <arfcn> <scs> <band>"
        set -- $nr_state
        shift  # remove "locked"
        nr_cell_json="{\"pci\":$1,\"arfcn\":$2,\"scs\":$3,\"band\":$4}"
        ;;
    error)
        qlog_warn "Failed to read NR-SA lock state"
        ;;
esac

# --- Parse persist state -----------------------------------------------------
persist_lte="false"
persist_nr="false"

set -- $persist_state
[ "$1" = "1" ] && persist_lte="true"
[ "$2" = "1" ] && persist_nr="true"

# --- Read config file (validated by tower_config_read) -----------------------
config_json=$(tower_config_read)

# --- Read failover state (no modem contact) ----------------------------------
failover_enabled="false"
failover_activated="false"
watcher_running="false"

# Check failover enabled from config using jq (safe extraction)
# NOTE: Do not use `// false` — jq's alternative operator treats `false` as
# falsy, so `false // false` always returns the alternative. Use direct access.
fo_val=$(printf '%s' "$config_json" | jq -r '.failover.enabled' 2>/dev/null)
[ "$fo_val" = "true" ] && failover_enabled="true"

# Check activation flag
[ -f "$TOWER_FAILOVER_FLAG" ] && failover_activated="true"

# Check watcher PID (must be live and match failover daemon command)
if command -v tower_get_running_failover_pid >/dev/null 2>&1; then
    if watcher_pid=$(tower_get_running_failover_pid); then
        [ -n "$watcher_pid" ] && watcher_running="true"
    fi
elif [ -f "$TOWER_FAILOVER_PID" ]; then
    watcher_pid=$(cat "$TOWER_FAILOVER_PID" 2>/dev/null | tr -d ' \n\r')
    if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then
        watcher_running="true"
    fi
fi

# --- Build response using jq (guaranteed valid JSON) -------------------------
# Construct modem_state as a JSON string
modem_json=$(jq -n \
    --argjson lte_locked "$lte_locked" \
    --argjson lte_cells "$lte_cells_json" \
    --argjson nr_locked "$nr_locked" \
    --argjson nr_cell "$nr_cell_json" \
    --argjson persist_lte "$persist_lte" \
    --argjson persist_nr "$persist_nr" \
    --argjson lte_read_ok "$lte_read_ok" \
    --argjson nr_read_ok "$nr_read_ok" \
    --argjson persist_read_ok "$persist_read_ok" \
    '{
        lte_locked: $lte_locked,
        lte_cells: $lte_cells,
        nr_locked: $nr_locked,
        nr_cell: $nr_cell,
        persist_lte: $persist_lte,
        persist_nr: $persist_nr,
        lte_read_ok: $lte_read_ok,
        nr_read_ok: $nr_read_ok,
        persist_read_ok: $persist_read_ok
    }' 2>/dev/null)

# Construct failover_state as a JSON string
failover_json=$(jq -n \
    --argjson enabled "$failover_enabled" \
    --argjson activated "$failover_activated" \
    --argjson watcher_running "$watcher_running" \
    '{
        enabled: $enabled,
        activated: $activated,
        watcher_running: $watcher_running
    }' 2>/dev/null)

# Combine everything into the final response
# config_json comes from the validated config file
# IMPORTANT: Capture into variable first to prevent double-output on partial failure
response_json=$(jq -n \
    --argjson modem "${modem_json:-null}" \
    --argjson config "${config_json:-null}" \
    --argjson failover "${failover_json:-null}" \
    '{
        success: true,
        modem_state: ($modem // {lte_locked:false,lte_cells:[],nr_locked:false,nr_cell:null,persist_lte:false,persist_nr:false}),
        config: $config,
        failover_state: ($failover // {enabled:false,activated:false,watcher_running:false})
    }' 2>/dev/null)

if [ -n "$response_json" ]; then
    printf '%s\n' "$response_json"
else
    # Fallback: jq failed entirely, produce a minimal valid response
    qlog_error "Failed to build status JSON with jq, sending fallback"
    printf '{"success":true,"modem_state":{"lte_locked":false,"lte_cells":[],"nr_locked":false,"nr_cell":null,"persist_lte":false,"persist_nr":false},"config":%s,"failover_state":{"enabled":false,"activated":false,"watcher_running":false}}\n' "$TOWER_DEFAULT_CONFIG"
fi
