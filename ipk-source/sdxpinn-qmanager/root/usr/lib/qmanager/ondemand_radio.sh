#!/bin/sh
# ondemand_radio.sh — On-demand Layer-1-adjacent radio reads.
#
# These reads (MIMO layers, timing advance, CGCONTRDP, CGPADDR) used to run
# on the recurring poller timer. They are L1/RF-measurement / data-plane reads:
# issuing them on a background timer eventually lands one mid-RAT-transition or
# mid-cell-reselection, which on the RM551E-GL correlates with a Qualcomm MPSS
# baseband SSR (recoverable radio restart). QuecManager — which lacks the drop
# bug — never polls these; it reads them only while the relevant UI page is open.
#
# This library relocates those reads OFF the recurring poller and behind an
# on-demand CGI endpoint. The poller's write_cache() reads last-known values
# back from /tmp/qmanager_ondemand.json so display fields retain their values
# between fetches (they are display-only and slow-changing).
#
# Source AFTER parse_at.sh (uses parse_mimo / parse_time_advance /
# parse_cgcontrdp / parse_serving_cell) and AFTER a logging library (qlog.sh or
# cgi_base.sh). The data CID / WAN IPs come from data_cid.sh (CGPADDR confirmed
# against the kernel route) -- no QMAP, which several firmwares do not implement.

[ -n "$_ONDEMAND_RADIO_LOADED" ] && return 0
_ONDEMAND_RADIO_LOADED=1

# Last-known on-demand radio values. Read by the poller's write_cache(), written
# by ondemand_radio_fetch(). Display-only; survives between on-demand fetches.
ONDEMAND_CACHE_FILE="/tmp/qmanager_ondemand.json"
ONDEMAND_CACHE_TMP="/tmp/qmanager_ondemand.json.tmp"

[ -f /usr/lib/qmanager/data_cid.sh ] && . /usr/lib/qmanager/data_cid.sh

# No-op logging fallbacks if sourced before a logging library.
command -v qlog_debug >/dev/null 2>&1 || qlog_debug() { :; }
command -v qlog_warn  >/dev/null 2>&1 || qlog_warn()  { :; }
command -v qlog_info  >/dev/null 2>&1 || qlog_info()  { :; }

# ---------------------------------------------------------------------------
# load_ondemand_cache
# Read last-known on-demand radio values from ONDEMAND_CACHE_FILE into the
# shell variables the poller's write_cache() emits. No-op (leaves whatever the
# caller already has) when the file is absent — so a first boot before any
# on-demand fetch simply emits the initialized-empty defaults.
#
# Populates:
#   t2_mimo, lte_ta, nr_ta,
#   t2_apn, t2_wan_ipv4, t2_wan_ipv6,
#   t2_primary_dns, t2_secondary_dns,
#   t2_primary_dns_v4, t2_primary_dns_v6,
#   t2_secondary_dns_v4, t2_secondary_dns_v6
# ---------------------------------------------------------------------------
load_ondemand_cache() {
    [ -s "$ONDEMAND_CACHE_FILE" ] || return 0

    # Emit the 12 fields in a fixed order, one value per line, then read them
    # back positionally. // handling is explicit: a missing key (or JSON null)
    # becomes an empty line. These fields are all display strings, so a missing
    # key legitimately means "no value known" — adopting empty is correct (the
    # poller no longer touches these, so we are not clobbering fresh data).
    # Newlines never appear inside any of these values (APN / IP / DNS /
    # mimo-label), so line-positional read is safe.
    _olc_dump=$(jq -r '
        (if .mimo == null then "" else .mimo end),
        (if .lte_ta == null then "" else .lte_ta end),
        (if .nr_ta == null then "" else .nr_ta end),
        (if .apn == null then "" else .apn end),
        (if .wan_ipv4 == null then "" else .wan_ipv4 end),
        (if .wan_ipv6 == null then "" else .wan_ipv6 end),
        (if .primary_dns == null then "" else .primary_dns end),
        (if .secondary_dns == null then "" else .secondary_dns end),
        (if .primary_dns_v4 == null then "" else .primary_dns_v4 end),
        (if .primary_dns_v6 == null then "" else .primary_dns_v6 end),
        (if .secondary_dns_v4 == null then "" else .secondary_dns_v4 end),
        (if .secondary_dns_v6 == null then "" else .secondary_dns_v6 end)
    ' "$ONDEMAND_CACHE_FILE" 2>/dev/null)

    [ -n "$_olc_dump" ] || return 0

    # Read the 12 lines positionally with builtins. IFS= keeps leading/trailing
    # blanks; a missing trailing line (the $( ) above strips trailing newlines)
    # reads as empty, so empty fields stay addressable.
    {
        IFS= read -r t2_mimo
        IFS= read -r lte_ta
        IFS= read -r nr_ta
        IFS= read -r t2_apn
        IFS= read -r t2_wan_ipv4
        IFS= read -r t2_wan_ipv6
        IFS= read -r t2_primary_dns
        IFS= read -r t2_secondary_dns
        IFS= read -r t2_primary_dns_v4
        IFS= read -r t2_primary_dns_v6
        IFS= read -r t2_secondary_dns_v4
        IFS= read -r t2_secondary_dns_v6
    } <<EOF
$_olc_dump
EOF

    unset _olc_dump
    return 0
}

# ---------------------------------------------------------------------------
# load_ondemand_cache_gated
# The poller's per-cycle entry point (write_cache). Re-parses the cache only
# when ONDEMAND_CACHE_FILE is newer than ONDEMAND_STAMP, plus a forced re-read
# every ONDEMAND_FORCE_EVERY calls (the poller passes ~30s of cycles) because
# [ -nt ] compares whole seconds: a write in the same second as the stamp would
# otherwise be missed. Other callers (ondemand_radio_fetch, the apply paths)
# use load_ondemand_cache directly and ALWAYS re-read; only this wrapper touches
# the stamp, so a CGI-side read can never hide a change from the poller.
# The stamp is set BEFORE the read, and backdated one second (touch -d, one fork
# per reload, not per cycle), so a write that lands in the same second as the
# read still compares newer next cycle; the cost is at most one redundant
# reload. A missing stamp (unwritable runtime dir) degrades to a re-read every
# call, i.e. the old behaviour.
# ---------------------------------------------------------------------------
ONDEMAND_STAMP="${ONDEMAND_STAMP:-/var/run/qmanager/ondemand.stamp}"
ONDEMAND_FORCE_EVERY="${TIER2_EVERY:-15}"
_olc_calls=0

# Sidecar (B5.29 Phase C): _ondemand_write_cache also writes the 12 values
# load_ondemand_cache extracts as shell assignments, so the poller can read them
# with builtins instead of a jq plus 12 reads. Written tmp + mv right after the
# JSON, so it is never older than the JSON it mirrors unless a write failed.
ONDEMAND_ENV="${ONDEMAND_ENV:-/var/run/qmanager/ondemand.env}"

# _od_env_source: source ONDEMAND_ENV only if every line is a single-quoted
# assignment and the last is the end marker (a syntax error in a dot-sourced file
# aborts the whole script). Returns 1 without sourcing otherwise.
_od_env_source() {
    _oes_last=""
    _oes_bad=0
    [ -f "$ONDEMAND_ENV" ] || return 1
    {
        while IFS= read -r _oes_l; do
            case "$_oes_l" in
                [A-Za-z_]*=\'*\') ;;
                *) _oes_bad=1 ;;
            esac
            _oes_last="$_oes_l"
        done < "$ONDEMAND_ENV"
    } 2>/dev/null
    [ "$_oes_bad" = "0" ] || return 1
    [ "$_oes_last" = "qm_sidecar_end='1'" ] || return 1
    . "$ONDEMAND_ENV"
}

# _od_sq <value>: _ODSQ = value single-quoted for sh ('  ->  '\'').
_od_sq() {
    _odsq_in="$1"
    _ODSQ=""
    while :; do
        case "$_odsq_in" in
            *\'*)
                _ODSQ="${_ODSQ}${_odsq_in%%\'*}'\\''"
                _odsq_in="${_odsq_in#*\'}"
                ;;
            *)
                _ODSQ="'${_ODSQ}${_odsq_in}'"
                break
                ;;
        esac
    done
}

# _ondemand_write_env: write the sidecar from the current t2_*/lte_ta/nr_ta
# values. Best effort: any failure leaves the previous file or none, and the
# poller then falls back to the JSON.
_ondemand_write_env() {
    _owe_dir="${ONDEMAND_ENV%/*}"
    [ -d "$_owe_dir" ] || mkdir -m 0700 "$_owe_dir" 2>/dev/null || return 1
    {
        _od_sq "${t2_mimo:-}";                printf 't2_mimo=%s\n' "$_ODSQ"
        _od_sq "${lte_ta:-}";                 printf 'lte_ta=%s\n' "$_ODSQ"
        _od_sq "${nr_ta:-}";                  printf 'nr_ta=%s\n' "$_ODSQ"
        _od_sq "${t2_apn:-}";                 printf 't2_apn=%s\n' "$_ODSQ"
        _od_sq "${t2_wan_ipv4:-}";            printf 't2_wan_ipv4=%s\n' "$_ODSQ"
        _od_sq "${t2_wan_ipv6:-}";            printf 't2_wan_ipv6=%s\n' "$_ODSQ"
        _od_sq "${t2_primary_dns:-}";         printf 't2_primary_dns=%s\n' "$_ODSQ"
        _od_sq "${t2_secondary_dns:-}";       printf 't2_secondary_dns=%s\n' "$_ODSQ"
        _od_sq "${t2_primary_dns_v4:-}";      printf 't2_primary_dns_v4=%s\n' "$_ODSQ"
        _od_sq "${t2_primary_dns_v6:-}";      printf 't2_primary_dns_v6=%s\n' "$_ODSQ"
        _od_sq "${t2_secondary_dns_v4:-}";    printf 't2_secondary_dns_v4=%s\n' "$_ODSQ"
        _od_sq "${t2_secondary_dns_v6:-}";    printf 't2_secondary_dns_v6=%s\n' "$_ODSQ"
        printf "qm_sidecar_end='1'\n"
    } 2>/dev/null > "${ONDEMAND_ENV}.new" \
        && mv -f "${ONDEMAND_ENV}.new" "$ONDEMAND_ENV" 2>/dev/null \
        || { rm -f "${ONDEMAND_ENV}.new" 2>/dev/null; return 1; }
    return 0
}

load_ondemand_cache_gated() {
    [ -s "$ONDEMAND_CACHE_FILE" ] || return 0
    # Sidecar first: pure builtins, so it is read every cycle with no stamp or
    # force counter. Used only when it is not older than the JSON.
    if [ -f "$ONDEMAND_ENV" ] && ! [ "$ONDEMAND_CACHE_FILE" -nt "$ONDEMAND_ENV" ]; then
        _od_env_source && return 0
    fi
    _olc_calls=$((_olc_calls + 1))
    if [ "$_olc_calls" -lt "$ONDEMAND_FORCE_EVERY" ] && [ -f "$ONDEMAND_STAMP" ] \
        && ! [ "$ONDEMAND_CACHE_FILE" -nt "$ONDEMAND_STAMP" ]; then
        return 0
    fi
    _olc_calls=0
    # `true`, not `:` — a redirect error on a special builtin exits the shell.
    if [ "${_NOW:-0}" -gt 1 ] 2>/dev/null; then
        touch -d "@$((_NOW - 1))" "$ONDEMAND_STAMP" 2>/dev/null || true 2>/dev/null > "$ONDEMAND_STAMP"
    else
        true 2>/dev/null > "$ONDEMAND_STAMP"
    fi
    load_ondemand_cache
    return 0
}

# ---------------------------------------------------------------------------
# _ondemand_write_cache
# Persist the current on-demand radio variables to ONDEMAND_CACHE_FILE so the
# poller (and the next fetch) retain last-known values. Atomic via tmp+mv.
# Internal — callers use ondemand_radio_fetch().
# ---------------------------------------------------------------------------
_ondemand_write_cache() {
    jq -n \
        --arg mimo    "${t2_mimo:-}" \
        --arg lte_ta  "${lte_ta:-}" \
        --arg nr_ta   "${nr_ta:-}" \
        --arg apn     "${t2_apn:-}" \
        --arg wan4    "${t2_wan_ipv4:-}" \
        --arg wan6    "${t2_wan_ipv6:-}" \
        --arg dns1    "${t2_primary_dns:-}" \
        --arg dns2    "${t2_secondary_dns:-}" \
        --arg dns1_v4 "${t2_primary_dns_v4:-}" \
        --arg dns1_v6 "${t2_primary_dns_v6:-}" \
        --arg dns2_v4 "${t2_secondary_dns_v4:-}" \
        --arg dns2_v6 "${t2_secondary_dns_v6:-}" \
        --arg ts      "$(date +%s)" \
        '{
            mimo: $mimo,
            lte_ta: $lte_ta,
            nr_ta: $nr_ta,
            apn: $apn,
            wan_ipv4: $wan4,
            wan_ipv6: $wan6,
            primary_dns: $dns1,
            secondary_dns: $dns2,
            primary_dns_v4: $dns1_v4,
            primary_dns_v6: $dns1_v6,
            secondary_dns_v4: $dns2_v4,
            secondary_dns_v6: $dns2_v6,
            updated_at: ($ts | tonumber)
        }' > "$ONDEMAND_CACHE_TMP" 2>/dev/null && mv "$ONDEMAND_CACHE_TMP" "$ONDEMAND_CACHE_FILE" || return 1
    _ondemand_write_env
    return 0
}

# ---------------------------------------------------------------------------
# ondemand_radio_fetch
# Run the relocated L1-adjacent / data-plane reads via qcmd, parse them into the
# t2_*/lte_ta/nr_ta shell vars, and persist to ONDEMAND_CACHE_FILE.
#
# RAT-gate hardening: mimo_layers crashes the firmware in the wrong RAT
# (lte_mimo_layers in SA, nr5g_mimo_layers in LTE/NSA). We re-read the serving
# cell FIRST (fresh, not cached) to learn the current RAT, then only issue the
# mode-appropriate mimo read. If the RAT is unknown / transitioning, we SKIP the
# mimo read entirely rather than issue it blindly. time_advance, CGCONTRDP and
# QMAP="WWAN" are mode-independent and always safe to read.
#
# Loads last-known values first so a partial/skipped read (e.g. mimo skipped
# during a RAT transition) does not blank a previously-good display value.
#
# Returns 0 if any AT response was received, 1 if the modem was entirely
# unreachable.
# ---------------------------------------------------------------------------
ondemand_radio_fetch() {
    # Start from last-known so a skipped/empty sub-read keeps the prior value.
    load_ondemand_cache

    local rat_now
    rat_now=""

    # --- Fresh RAT read (gates mimo) ---------------------------------------
    local sc_result
    sc_result=$(qcmd 'AT+QENG="servingcell"' 2>/dev/null)
    if [ -n "$sc_result" ]; then
        # parse_serving_cell sets network_type (5G-SA / 5G-NSA / LTE / "")
        local _prev_nt
        _prev_nt="$network_type"
        parse_serving_cell "$sc_result"
        rat_now="$network_type"
        # Restore the caller's network_type if we learned nothing new (avoid
        # leaking a transient empty RAT into a long-lived poller var).
        [ -z "$rat_now" ] && network_type="$_prev_nt"
    fi

    # --- Group 1: APN + WAN IPs (always safe, mode-independent) -------------
    local g1
    g1=$(qcmd 'AT+CGPADDR;+CGCONTRDP' 2>/dev/null)
    [ -n "$g1" ] && _ondemand_apply_dataplane "$g1"

    # --- Group 2: NR timing + (SA-only) NR MIMO ----------------------------
    local nr_cmd
    nr_cmd='AT+QNWCFG="nr5g_time_advance"'
    if [ "$rat_now" = "5G-SA" ]; then
        nr_cmd="${nr_cmd}"';+QNWCFG="nr5g_mimo_layers"'
    fi
    local g2
    g2=$(qcmd "$nr_cmd" 2>/dev/null)
    if [ -n "$g2" ]; then
        parse_time_advance "$g2"
        parse_mimo "" "$g2"
    fi

    # --- Group 3: LTE timing + (LTE/NSA-only) LTE MIMO ---------------------
    local lte_cmd
    lte_cmd='AT+QNWCFG="lte_time_advance"'
    if [ "$rat_now" = "LTE" ] || [ "$rat_now" = "5G-NSA" ]; then
        lte_cmd="${lte_cmd}"';+QNWCFG="lte_mimo_layers"'
    fi
    local g3
    g3=$(qcmd "$lte_cmd" 2>/dev/null)
    if [ -n "$g3" ]; then
        parse_time_advance "$g3"
        parse_mimo "$g3" ""
    fi

    if [ -z "$sc_result" ] && [ -z "$g1" ] && [ -z "$g2" ] && [ -z "$g3" ]; then
        qlog_warn "ondemand_radio_fetch: modem unreachable (no AT responses)"
        return 1
    fi

    _ondemand_write_cache
    qlog_debug "ondemand_radio_fetch: rat=$rat_now mimo=$t2_mimo lte_ta=$lte_ta nr_ta=$nr_ta apn=$t2_apn"
    return 0
}

# ---------------------------------------------------------------------------
# _ondemand_apply_dataplane <AT+CGPADDR;+CGCONTRDP reply>
# Resolve the data CID (data_cid.sh: CGPADDR confirmed against the kernel
# default route), take the WAN IPs from that CID's CGPADDR entry (t2_wan_ipv4 /
# t2_wan_ipv6 -- cleared when no bearer is up, never left stale), and parse the
# APN / DNS from the same CID's CGCONTRDP record. Without data_cid.sh it
# degrades to the legacy parse (CID 1, WAN IPs untouched).
# ---------------------------------------------------------------------------
_ondemand_apply_dataplane() {
    local blob
    local cid
    blob=$(printf '%s\n' "$1" | tr -d '\r')
    cid=""
    if command -v qm_detect_data_cid >/dev/null 2>&1; then
        qm_detect_data_cid "$blob"
        cid="$QM_DATA_CID"
        t2_wan_ipv4="$QM_DATA_IPV4"
        t2_wan_ipv6="$QM_DATA_IPV6"
    fi
    if printf '%s\n' "$blob" | grep -q '+CGCONTRDP:'; then
        parse_cgcontrdp "$blob" "$cid"
    fi
}

# ---------------------------------------------------------------------------
# ondemand_dataplane_refresh
# Refresh ONLY the safe, mode-independent data-plane group (APN / DNS / WAN IP)
# into the on-demand cache. Deliberately issues NO mimo / time_advance / L1
# read — it is meant to be called by APN / profile apply paths right after a
# COPS re-register, when the radio is mid-attach and an L1 read would be exactly
# the dangerous moment this whole change avoids. CGPADDR and CGCONTRDP are
# PDP reads, safe in any RAT and not L1 measurements.
#
# Loads last-known first so the mimo / TA fields the apply does NOT touch are
# preserved in the rewritten cache file.
#
# Returns 0 if the data-plane read returned anything, 1 otherwise.
# ---------------------------------------------------------------------------
ondemand_dataplane_refresh() {
    load_ondemand_cache

    local dp
    dp=$(qcmd 'AT+CGPADDR;+CGCONTRDP' 2>/dev/null)
    if [ -z "$dp" ]; then
        qlog_warn "ondemand_dataplane_refresh: no AT response"
        return 1
    fi

    _ondemand_apply_dataplane "$dp"

    _ondemand_write_cache
    qlog_debug "ondemand_dataplane_refresh: apn=$t2_apn wan4=$t2_wan_ipv4"
    return 0
}
