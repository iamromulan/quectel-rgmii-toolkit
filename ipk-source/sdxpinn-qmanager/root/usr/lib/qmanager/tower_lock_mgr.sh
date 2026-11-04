#!/bin/sh
# =============================================================================
# tower_lock_mgr.sh — QManager Tower Lock Manager Library
# =============================================================================
# A sourceable library providing tower lock config CRUD, AT command
# builders/parsers, and signal quality calculation.
#
# This is a LIBRARY — no persistent process, no polling.
# CGI scripts and the failover/schedule scripts source it.
#
# Dependencies: qcmd, qlog_* functions (from qlog.sh), jq
# Install location: /usr/lib/qmanager/tower_lock_mgr.sh
#
# Usage:
#   . /usr/lib/qmanager/tower_lock_mgr.sh
#   tower_config_read             → Cat config JSON to stdout
#   tower_config_init             → Create default config if missing
#   tower_config_get <jq_path>    → Extract value via jq (e.g., ".failover.enabled")
#   tower_config_update <filter>  → Update config via jq filter
#   tower_lock_lte <n> <pairs>    → Send AT+QNWLOCK="common/4g" command
#   tower_unlock_lte              → Clear LTE lock
#   tower_lock_nr <pci> <arfcn> <scs> <band> → Send AT+QNWLOCK="common/5g"
#   tower_unlock_nr               → Clear NR-SA lock
#   tower_read_lte_lock           → Query and parse LTE lock state
#   tower_read_nr_lock            → Query and parse NR-SA lock state
#   tower_set_persist <lte> <nr>  → Send AT+QNWLOCK="save_ctrl",<lte>,<nr> (each 0|1)
#   tower_read_persist            → Query and parse persist state
#   calc_signal_quality <rsrp>    → Returns 0-100 integer
# =============================================================================

[ -n "$_TOWER_LOCK_MGR_LOADED" ] && return 0
_TOWER_LOCK_MGR_LOADED=1

# --- Configuration -----------------------------------------------------------
TOWER_CONFIG_FILE="/etc/qmanager/tower_lock.json"
TOWER_FAILOVER_FLAG="/tmp/qmanager_tower_failover"
TOWER_FAILOVER_PID="/tmp/qmanager_tower_failover.pid"
TOWER_FAILOVER_SCRIPT="/usr/bin/qmanager_tower_failover"

# Ensure config directory exists
mkdir -p /etc/qmanager 2>/dev/null

# --- Default config as a constant (used by init and validation) ---------------
TOWER_DEFAULT_CONFIG='{"lte":{"enabled":false,"cells":[null,null,null]},"nr_sa":{"enabled":false,"pci":null,"arfcn":null,"scs":null,"band":null},"persist":false,"failover":{"enabled":false,"threshold":20},"schedule":{"enabled":false,"start_time":"08:00","end_time":"22:00","days":[1,2,3,4,5]}}'

# =============================================================================
# Config File Operations (all use jq for guaranteed valid JSON)
# =============================================================================

# Create default config file if it doesn't exist or is invalid
tower_config_init() {
    if [ -f "$TOWER_CONFIG_FILE" ]; then
        # Validate existing file with jq
        if jq empty "$TOWER_CONFIG_FILE" 2>/dev/null; then
            return 0
        fi
        qlog_warn "Tower config file is invalid JSON, recreating"
    fi

    local tmp="${TOWER_CONFIG_FILE}.tmp"
    printf '%s\n' "$TOWER_DEFAULT_CONFIG" | jq '.' > "$tmp" && mv "$tmp" "$TOWER_CONFIG_FILE"
    qlog_info "Created default tower lock config"
}

# Read the entire config file to stdout (validated)
# Falls back to default if file is missing or invalid
tower_config_read() {
    if [ -f "$TOWER_CONFIG_FILE" ] && jq empty "$TOWER_CONFIG_FILE" 2>/dev/null; then
        cat "$TOWER_CONFIG_FILE"
    else
        qlog_warn "Tower config missing or invalid, returning default"
        printf '%s\n' "$TOWER_DEFAULT_CONFIG"
    fi
}

# Extract a value from the config using a jq path
# Args: $1=jq filter expression (e.g., ".failover.enabled", ".lte.cells")
# Returns: raw value (no quotes for strings unless you use jq -r)
tower_config_get() {
    local filter="$1"
    tower_config_init
    # NOTE: Cannot use `// empty` — jq treats `false` as falsy so
    # `false // empty` produces nothing. Use explicit null check instead.
    jq -r "($filter) | if . == null then empty else tostring end" "$TOWER_CONFIG_FILE" 2>/dev/null
}

# Update the config file using a jq filter expression
# The filter is applied to the current config and the result is written back.
# Args: $1=jq filter expression (e.g., '.persist = true')
# Returns: 0 on success, 1 on failure
tower_config_update() {
    local filter="$1"
    tower_config_init

    local tmp="${TOWER_CONFIG_FILE}.tmp"
    if jq "$filter" "$TOWER_CONFIG_FILE" > "$tmp" 2>/dev/null; then
        # Validate the output
        if jq empty "$tmp" 2>/dev/null; then
            mv "$tmp" "$TOWER_CONFIG_FILE"
            return 0
        fi
    fi

    rm -f "$tmp"
    qlog_error "tower_config_update failed for filter: $filter"
    return 1
}

# =============================================================================
# LTE Lock Config Update (uses jq — safe, atomic)
# =============================================================================
# Args: $1=enabled (true/false), $2=cell1_earfcn, $3=cell1_pci,
#       $4=cell2_earfcn, $5=cell2_pci, $6=cell3_earfcn, $7=cell3_pci
# Empty earfcn/pci pairs become null slots.
tower_config_update_lte() {
    local enabled="$1"
    local c1_e="$2" c1_p="$3" c2_e="$4" c2_p="$5" c3_e="$6" c3_p="$7"

    # Build cells array in JSON
    local cell1="null" cell2="null" cell3="null"
    [ -n "$c1_e" ] && [ -n "$c1_p" ] && cell1="{\"earfcn\":$c1_e,\"pci\":$c1_p}"
    [ -n "$c2_e" ] && [ -n "$c2_p" ] && cell2="{\"earfcn\":$c2_e,\"pci\":$c2_p}"
    [ -n "$c3_e" ] && [ -n "$c3_p" ] && cell3="{\"earfcn\":$c3_e,\"pci\":$c3_p}"

    tower_config_update ".lte.enabled = $enabled | .lte.cells = [$cell1, $cell2, $cell3]"
}

# =============================================================================
# NR-SA Lock Config Update (uses jq — safe, atomic)
# =============================================================================
# Args: $1=enabled (true/false), $2=pci, $3=arfcn, $4=scs, $5=band
tower_config_update_nr() {
    local enabled="$1"
    local pci="${2:-null}" arfcn="${3:-null}" scs="${4:-null}" band="${5:-null}"

    tower_config_update ".nr_sa.enabled = $enabled | .nr_sa.pci = $pci | .nr_sa.arfcn = $arfcn | .nr_sa.scs = $scs | .nr_sa.band = $band"
}

# =============================================================================
# Settings Config Update (persist + failover) — uses jq
# =============================================================================
# Args: $1=persist(true/false), $2=failover_enabled(true/false), $3=threshold
tower_config_update_settings() {
    local persist="$1" fo_enabled="$2" fo_threshold="$3"

    tower_config_update ".persist = $persist | .failover.enabled = $fo_enabled | .failover.threshold = $fo_threshold"
}

# =============================================================================
# Schedule Config Update — uses jq
# =============================================================================
# Args: $1=enabled(true/false), $2=start_time, $3=end_time, $4=days_json_array
tower_config_update_schedule() {
    local enabled="$1" start_time="$2" end_time="$3" days_json="$4"

    tower_config_update ".schedule.enabled = $enabled | .schedule.start_time = \"$start_time\" | .schedule.end_time = \"$end_time\" | .schedule.days = $days_json"
}

# =============================================================================
# AT Command Operations — LTE Tower Lock
# =============================================================================

# Send LTE tower lock command
# Args: $1=num_cells, then pairs: $2=earfcn1, $3=pci1, $4=earfcn2, $5=pci2, ...
tower_lock_lte() {
    local num="$1"
    shift
    local cmd="AT+QNWLOCK=\"common/4g\",$num"
    while [ $# -ge 2 ]; do
        cmd="${cmd},$1,$2"
        shift 2
    done
    qlog_info "LTE tower lock: $cmd"
    local result
    result=$(qcmd "$cmd" 2>/dev/null)
    local rc=$?
    printf '%s' "$result"
    return $rc
}

# Clear LTE tower lock
tower_unlock_lte() {
    qlog_info "Clearing LTE tower lock"
    local result
    result=$(qcmd 'AT+QNWLOCK="common/4g",0' 2>/dev/null)
    local rc=$?
    printf '%s' "$result"
    return $rc
}

# Query current LTE lock state
# Output: "locked <num_cells> <earfcn1> <pci1> [<earfcn2> <pci2> ...]" or "unlocked"
tower_read_lte_lock() {
    local result
    result=$(qcmd 'AT+QNWLOCK="common/4g"' 2>/dev/null)
    local rc=$?

    if [ $rc -ne 0 ] || [ -z "$result" ]; then
        printf 'error'
        return 1
    fi

    # Parse response: +QNWLOCK: "common/4g",<num>,<freq>,<pci>[,...]
    # or: +QNWLOCK: "common/4g",0
    local line
    line=$(printf '%s' "$result" | grep '+QNWLOCK:' | head -1 | tr -d '\r')

    if [ -z "$line" ]; then
        printf 'error'
        return 1
    fi

    # Extract everything after "common/4g",
    local params
    params=$(printf '%s' "$line" | sed 's/.*"common\/4g",//' | tr -d ' ')

    # First param is num_cells (or 0 for unlocked)
    local num_cells
    num_cells=$(printf '%s' "$params" | cut -d',' -f1)

    if [ "$num_cells" = "0" ] || [ -z "$num_cells" ]; then
        printf 'unlocked'
        return 0
    fi

    # Output: locked <num_cells> <earfcn1> <pci1> ...
    printf 'locked %s' "$num_cells"
    local remaining
    remaining=$(printf '%s' "$params" | sed 's/^[^,]*,//')
    # Parse pairs
    local i=0
    while [ $i -lt "$num_cells" ] && [ -n "$remaining" ]; do
        local earfcn pci
        earfcn=$(printf '%s' "$remaining" | cut -d',' -f1)
        pci=$(printf '%s' "$remaining" | cut -d',' -f2)
        printf ' %s %s' "$earfcn" "$pci"
        # Remove the consumed pair
        remaining=$(printf '%s' "$remaining" | sed 's/^[^,]*,[^,]*//' | sed 's/^,//')
        i=$((i + 1))
    done

    return 0
}

# =============================================================================
# AT Command Operations — NR-SA Tower Lock
# =============================================================================

# Send NR-SA tower lock command
# Args: $1=pci, $2=arfcn, $3=scs, $4=band
tower_lock_nr() {
    local pci="$1" arfcn="$2" scs="$3" band="$4"
    local cmd="AT+QNWLOCK=\"common/5g\",$pci,$arfcn,$scs,$band"
    qlog_info "NR-SA tower lock: $cmd"
    local result
    result=$(qcmd "$cmd" 2>/dev/null)
    local rc=$?
    printf '%s' "$result"
    return $rc
}

# Clear NR-SA tower lock
tower_unlock_nr() {
    qlog_info "Clearing NR-SA tower lock"
    local result
    result=$(qcmd 'AT+QNWLOCK="common/5g",0' 2>/dev/null)
    local rc=$?
    printf '%s' "$result"
    return $rc
}

# Query current NR-SA lock state
# Output: "locked <pci> <arfcn> <scs> <band>" or "unlocked"
tower_read_nr_lock() {
    local result
    result=$(qcmd 'AT+QNWLOCK="common/5g"' 2>/dev/null)
    local rc=$?

    if [ $rc -ne 0 ] || [ -z "$result" ]; then
        printf 'error'
        return 1
    fi

    local line
    line=$(printf '%s' "$result" | grep '+QNWLOCK:' | head -1 | tr -d '\r')

    if [ -z "$line" ]; then
        # No +QNWLOCK line is an unanswered read, not "unlocked": an OK-only
        # reply carries no lock state. Fail closed like the LTE twin.
        printf 'error'
        return 1
    fi

    # Extract params after "common/5g"
    local params
    params=$(printf '%s' "$line" | sed 's/.*"common\/5g"//' | sed 's/^,//' | tr -d ' ')

    # If empty or just the key with no params — unlocked
    if [ -z "$params" ] || [ "$params" = "0" ]; then
        printf 'unlocked'
        return 0
    fi

    # Locked: params = <pci>,<arfcn>,<scs>,<band>
    local pci arfcn scs band
    pci=$(printf '%s' "$params" | cut -d',' -f1)
    arfcn=$(printf '%s' "$params" | cut -d',' -f2)
    scs=$(printf '%s' "$params" | cut -d',' -f3)
    band=$(printf '%s' "$params" | cut -d',' -f4)

    printf 'locked %s %s %s %s' "$pci" "$arfcn" "$scs" "$band"
    return 0
}

# =============================================================================
# AT Command Operations — Persistence Control
# =============================================================================

# Set persistence for the LTE and NR locks. The modem takes both values in one
# command, so a caller changing one radio passes the other's current value.
# Args: $1=lte (0 or 1), $2=nr (0 or 1)
tower_set_persist() {
    local lte="$1" nr="$2"
    qlog_info "Setting tower lock persistence: lte=$lte nr=$nr"
    local result
    result=$(qcmd "AT+QNWLOCK=\"save_ctrl\",$lte,$nr" 2>/dev/null)
    local rc=$?
    printf '%s' "$result"
    return $rc
}

# Read current persistence state
# Output: "<lte_ctrl> <nr_ctrl>" (e.g., "1 1" or "0 0")
tower_read_persist() {
    local result
    result=$(qcmd 'AT+QNWLOCK="save_ctrl"' 2>/dev/null)
    local rc=$?

    if [ $rc -ne 0 ] || [ -z "$result" ]; then
        printf '0 0'
        return 1
    fi

    local line
    line=$(printf '%s' "$result" | grep '+QNWLOCK:' | head -1 | tr -d '\r')

    if [ -z "$line" ]; then
        printf '0 0'
        return 1
    fi

    # +QNWLOCK: "save_ctrl",<lte>,<nr>
    local params
    params=$(printf '%s' "$line" | sed 's/.*"save_ctrl",//' | tr -d ' ')
    local lte_ctrl nr_ctrl
    lte_ctrl=$(printf '%s' "$params" | cut -d',' -f1)
    nr_ctrl=$(printf '%s' "$params" | cut -d',' -f2)
    [ -z "$lte_ctrl" ] && lte_ctrl="0"
    [ -z "$nr_ctrl" ] && nr_ctrl="0"

    printf '%s %s' "$lte_ctrl" "$nr_ctrl"
    return 0
}

# =============================================================================
# Signal Quality Calculation
# =============================================================================

# Calculate signal quality percentage from RSRP
# Formula: clamp(0, 100, ((rsrp + 140) * 100) / 60)
# Maps: -140 dBm → 0%, -80 dBm → 100%
# Args: $1=rsrp (integer, e.g., -95)
# Output: integer 0-100
calc_signal_quality() {
    local rsrp="$1"

    # Validate input
    case "$rsrp" in
        ''|*[!0-9-]*) printf '0'; return 1 ;;
    esac

    local quality
    quality=$(( (rsrp + 140) * 100 / 60 ))
    [ "$quality" -lt 0 ] && quality=0
    [ "$quality" -gt 100 ] && quality=100
    printf '%s' "$quality"
    return 0
}

# =============================================================================
# Failover Watcher Management
# =============================================================================

# Check whether a PID is the live tower failover daemon process.
# Returns 0 when alive and command line matches qmanager_tower_failover.
tower_is_failover_pid_running() {
    local pid="$1"

    [ -n "$pid" ] || return 1
    case "$pid" in
        *[!0-9]*) return 1 ;;
    esac

    kill -0 "$pid" 2>/dev/null || return 1

    local cmdline
    cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    case "$cmdline" in
        *"$TOWER_FAILOVER_SCRIPT"*) return 0 ;;
    esac

    return 1
}

# Read watcher PID file and return a verified live daemon PID.
# Cleans up stale PID files automatically.
tower_get_running_failover_pid() {
    local pid

    [ -f "$TOWER_FAILOVER_PID" ] || return 1
    pid=$(cat "$TOWER_FAILOVER_PID" 2>/dev/null | tr -d ' \n\r')

    if tower_is_failover_pid_running "$pid"; then
        printf '%s' "$pid"
        return 0
    fi

    rm -f "$TOWER_FAILOVER_PID"
    return 1
}

# Kill any running failover watcher (delegates to init.d)
tower_kill_failover_watcher() {
    /etc/init.d/qmanager_tower_failover stop 2>/dev/null
}

# Spawn failover watcher if enabled (delegates to init.d)
# Returns: "true" if daemon verified running, "false" if not spawned or failed
tower_spawn_failover_watcher() {
    # Check if failover is enabled in config
    local fo_enabled
    fo_enabled=$(tower_config_get ".failover.enabled")

    if [ "$fo_enabled" != "true" ]; then
        printf 'false'
        return 0
    fi

    # Stop any existing watcher, then start fresh via init.d
    /etc/init.d/qmanager_tower_failover stop 2>/dev/null
    /etc/init.d/qmanager_tower_failover start 2>/dev/null

    # Enable for boot auto-start (creates /etc/rc.d symlink, shows in LuCI)
    /etc/init.d/qmanager_tower_failover enable 2>/dev/null

    # Verify daemon actually started (PID file written immediately on spawn)
    sleep 1
    local pid
    pid=$(tower_get_running_failover_pid)
    if [ -n "$pid" ]; then
        qlog_info "Tower failover watcher verified running (PID=$pid)"
        printf 'true'
        return 0
    fi

    qlog_warn "Tower failover watcher failed to start"
    printf 'false'
    return 1
}

# =============================================================================
# MTU Re-apply After Interface Bounce
# =============================================================================
# Tower lock/unlock causes the modem to briefly disconnect, which resets the
# rmnet_data interface MTU back to the default 1500. The persistent file
# /etc/firewall.user.mtu is intact but nothing re-applies it.
#
# This spawns a short-lived background process that polls until the interface
# is back up, re-applies MTU, then exits. Self-terminates after 30s.
#
# PID file ensures only one re-apply process runs at a time.
# =============================================================================

[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh
# B5.11: root-only run dir; the worker records its OWN pid (qm_self_pid), not
# its caller's $$, so a second re-apply never signals the calling daemon.
MTU_REAPPLY_PID="/var/run/qmanager/mtu_reapply.pid"
MTU_FILE="/etc/firewall.user.mtu"

mtu_reapply_after_bounce() {
    # Skip if no custom MTU is configured
    if [ ! -s "$MTU_FILE" ]; then
        return 0
    fi

    # Fail closed without the safe_tmp helpers or the root-only run dir
    if ! command -v qm_read_pid >/dev/null 2>&1 || ! qm_run_dir >/dev/null; then
        qlog_warn "MTU re-apply skipped: cannot prepare the state directory"
        return 0
    fi

    # Kill any previous re-apply process
    if [ -f "$MTU_REAPPLY_PID" ]; then
        local old_pid
        # The worker is a fork of its caller, so its cmdline is the caller's:
        # a qmanager_* daemon/worker or the tower/lock.sh CGI.
        old_pid=$(qm_read_pid "$MTU_REAPPLY_PID" qmanager_ \
            || qm_read_pid "$MTU_REAPPLY_PID" tower/lock.sh)
        if [ -n "$old_pid" ]; then
            kill "$old_pid" 2>/dev/null
        fi
        rm -f "$MTU_REAPPLY_PID"
    fi

    qlog_info "Spawning MTU re-apply watcher (polling up to 30s)"

    # Double-fork for BusyBox (no setsid). Worker writes its own PID as
    # the very first action, eliminating the race between fork and PID write.
    (
        _mtu_reapply_worker </dev/null >/dev/null 2>&1 &
    )
}

# Sleep for N milliseconds. Uses usleep when available. On systems
# without usleep, sleeps 1s for <1000ms requests (BusyBox sleep is
# integer seconds only) or (ms/1000)s for >=1000ms requests.
_mtu_sleep_ms() {
    local ms="$1"
    if command -v usleep >/dev/null 2>&1; then
        usleep $((ms * 1000)) 2>/dev/null && return 0
    fi
    if [ "$ms" -ge 1000 ]; then
        sleep $((ms / 1000))
    else
        sleep 1
    fi
}

_mtu_reapply_worker() {
    # Worker writes its own PID first — eliminates the race window between
    # fork in mtu_reapply_after_bounce and a second caller's guard check.
    # $$ would be the caller's pid in this subshell; record our own
    qm_self_pid && printf '%s\n' "$QM_SELF_PID" | qm_atomic_write "$MTU_REAPPLY_PID"

    # Wait for an rmnet_data interface with carrier=1, then keep watching
    # MTU until it stays at the expected value for two consecutive reads.
    # The Quectel RMNET driver can reset MTU asynchronously after the
    # carrier comes up, and again after we correct it. Budget: ~30s total.

    local deadline max_wait
    max_wait=30
    deadline=$(( $(date +%s) + max_wait ))

    # Phase 1: wait for carrier=1 on any rmnet_data* iface (poll every 500ms)
    local iface=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        for f in /sys/class/net/rmnet_data*; do
            [ -e "$f" ] || continue
            local name carrier
            name=$(basename "$f")
            carrier=$(cat "/sys/class/net/${name}/carrier" 2>/dev/null)
            if [ "$carrier" = "1" ]; then
                iface="$name"
                break
            fi
        done
        [ -n "$iface" ] && break
        _mtu_sleep_ms 500
    done

    if [ -z "$iface" ]; then
        logger -t qmanager_mtu "MTU re-apply timed out waiting for rmnet_data carrier"
        rm -f "$MTU_REAPPLY_PID"
        return 1
    fi

    # Parse expected MTU once. If unparseable, nothing to enforce.
    local expected_mtu
    expected_mtu=$(awk '/mtu [0-9]/{for(i=1;i<=NF;i++) if($i=="mtu") {print $(i+1); exit}}' "$MTU_FILE")
    if [ -z "$expected_mtu" ]; then
        rm -f "$MTU_REAPPLY_PID"
        return 0
    fi

    # Phase 2: settle + verify + retry loop.
    # Goal: observe MTU == expected on two consecutive reads (1s apart) before
    # declaring success. Re-apply on each mismatch. Max 3 re-apply attempts.
    local retries=3
    local stable_hits=0
    local last_applied_from=""
    local current_mtu=""

    # Let the driver finish any pending reset before first measurement.
    _mtu_sleep_ms 500

    while [ "$(date +%s)" -lt "$deadline" ]; do
        current_mtu=$(cat "/sys/class/net/${iface}/mtu" 2>/dev/null)

        if [ "$current_mtu" = "$expected_mtu" ]; then
            stable_hits=$((stable_hits + 1))
            if [ "$stable_hits" -ge 2 ]; then
                if [ -n "$last_applied_from" ]; then
                    logger -t qmanager_mtu "MTU stable at ${expected_mtu} on ${iface} (re-applied from ${last_applied_from})"
                else
                    logger -t qmanager_mtu "MTU already correct at ${expected_mtu} on ${iface} — no re-apply needed"
                fi
                rm -f "$MTU_REAPPLY_PID"
                return 0
            fi
            _mtu_sleep_ms 1000
            continue
        fi

        # Mismatch — reset stability counter and try to re-apply.
        stable_hits=0

        if [ "$retries" -le 0 ]; then
            logger -t qmanager_mtu "MTU re-apply exhausted retries (current=${current_mtu}, expected=${expected_mtu}, iface=${iface})"
            rm -f "$MTU_REAPPLY_PID"
            return 1
        fi

        last_applied_from="$current_mtu"
        # MTU_FILE is written exclusively by the MTU CGI (mtu.sh) and
        # contains only "ip link set <iface> mtu <value>" lines. Sourcing
        # it as root is intentional; treat it as trusted input.
        . "$MTU_FILE"
        retries=$((retries - 1))

        # Give the kernel a moment to apply, then fall through to re-check.
        _mtu_sleep_ms 200
    done

    logger -t qmanager_mtu "MTU re-apply timed out after ${max_wait}s (iface=${iface}, last=${current_mtu:-unknown}, expected=${expected_mtu})"
    rm -f "$MTU_REAPPLY_PID"
    return 1
}
