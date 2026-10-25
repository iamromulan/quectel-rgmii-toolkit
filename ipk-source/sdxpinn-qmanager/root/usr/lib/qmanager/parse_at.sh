#!/bin/sh
# =============================================================================
# parse_at.sh — AT Command Response Parsers for QManager
# =============================================================================
# Sourced by qmanager_poller. All functions here operate on raw AT command
# response strings and populate global state variables defined in the poller.
#
# Dependencies: qlog_* functions (from qlog.sh), global state variables
# Install location: /usr/lib/qmanager/parse_at.sh
# =============================================================================

[ -n "$_PARSE_AT_LOADED" ] && return 0
_PARSE_AT_LOADED=1

# --- Fork-free parsing primitives ---------------------------------------------
# The poller runs these parsers every cycle; each $(...) / pipe used to cost a
# fork (2-8 ms on this CPU). Everything below is builtins only. Results come back
# through globals instead of command substitution:
#   _R      result of the *_g helpers
#   _S      working string of the _pat_* string helpers
#   _F1-17  fields written by _pat_split
# The old echo-style helper names are kept below as thin wrappers.
_PA_NL='
'
_PA_CR=$(printf '\r')

# Remove every occurrence of the literal "$1" from _S, left to right and
# non-overlapping (== sed "s/$1//g" for a literal pattern). $1 must be non-empty.
_pat_del() {
    local rest="$_S"
    local out=""
    while :; do
        case $rest in
            *"$1"*)
                out=$out${rest%%"$1"*}
                rest=${rest#*"$1"}
                ;;
            *) break ;;
        esac
    done
    _S=$out$rest
}

# Split _S on commas into _F1.._F17 with `cut -d, -fN` semantics: a line with no
# comma yields the whole line for every N; fields past the end (including a
# dropped trailing empty field) are empty. Globbing is off and IFS is restored.
_pat_split() {
    local oifs=""
    local ifs_set=0
    local noglob=0
    case ${IFS+s} in s) oifs=$IFS ; ifs_set=1 ;; esac
    case $- in *f*) noglob=1 ;; esac
    case $_S in
        *,*) ;;
        *) _S=$_S,$_S,$_S,$_S,$_S,$_S,$_S,$_S,$_S,$_S,$_S,$_S,$_S,$_S,$_S,$_S,$_S,$_S ;;
    esac
    IFS=,
    set -f
    set -- $_S
    if [ "$ifs_set" = 1 ]; then IFS=$oifs; else unset IFS; fi
    [ "$noglob" = 1 ] || set +f
    _F1=$1 ; _F2=$2 ; _F3=$3 ; _F4=$4 ; _F5=$5 ; _F6=$6 ; _F7=$7 ; _F8=$8 ; _F9=$9
    _F10=${10} ; _F11=${11} ; _F12=${12} ; _F13=${13} ; _F14=${14} ; _F15=${15}
    _F16=${16} ; _F17=${17}
}

# Sets _pat_line to the first line of $1 containing the literal $2 (else "").
_pat_first_line() {
    local rest="$1"
    local line
    local more=1
    _pat_line=""
    while [ "$more" = 1 ]; do
        case $rest in
            *"$_PA_NL"*)
                line=${rest%%"$_PA_NL"*}
                rest=${rest#*"$_PA_NL"}
                ;;
            *)
                line=$rest
                rest=""
                more=0
                ;;
        esac
        case $line in
            *"$2"*) _pat_line=$line ; return 0 ;;
        esac
    done
    return 0
}

# --- Sentinel Value Mapping ---------------------------------------------------
# Maps Quectel sentinel values to JSON null for inactive/unavailable antennas.
# Global-setting variant (hot path): sets _R. Values made only of digits and '-'
# are passed through directly; anything else goes through the original echo
# helper so exotic text is reproduced byte for byte.
_sig_val_g() {
    case "$1" in
        -32768|"") _R="null" ;;
        *[!0-9-]*) _R=$(_sig_val "$1") ;;
        *) _R="$1" ;;
    esac
}

_sig_val() {
    case "$1" in
        -32768|"") echo "null" ;;
        *) echo "$1" ;;
    esac
}

# Convert 4 antenna values to a JSON array string with sentinel mapping.
# Usage: _antenna_to_json_array_g val0 val1 val2 val3   -> _R="[-95,-97,null,null]"
_antenna_to_json_array_g() {
    local a
    local b
    local c
    _sig_val_g "$1" ; a=$_R
    _sig_val_g "$2" ; b=$_R
    _sig_val_g "$3" ; c=$_R
    _sig_val_g "$4"
    _R="[$a,$b,$c,$_R]"
}

# Usage: _antenna_to_json_array val0 val1 val2 val3
# Output: "[-95,-97,null,null]"
_antenna_to_json_array() {
    _antenna_to_json_array_g "$1" "$2" "$3" "$4"
    printf '%s' "$_R"
}

# Parse a single response line from AT+QRSRP/QRSRQ/QSINR into a JSON array.
# Args: $1=response line (may be empty), $2=prefix (e.g. "QRSRP")
# Global-setting variant: sets _R. The first "+<prefix>:" is removed (sed
# non-global), then every space and CR, then the comma fields are read.
_antenna_line_to_json_g() {
    if [ -z "$1" ]; then
        _R="[null,null,null,null]"
        return 0
    fi
    local key="+$2:"
    _S=$1
    case $_S in
        *"$key"*) _S=${_S%%"$key"*}${_S#*"$key"} ;;
    esac
    _pat_del ' '
    _pat_del "$_PA_CR"
    _pat_split
    _antenna_to_json_array_g "$_F1" "$_F2" "$_F3" "$_F4"
}

# Output: JSON array string like "[-95,-97,null,null]" on stdout
_antenna_line_to_json() {
    if [ -z "$1" ]; then
        echo "[null,null,null,null]"
        return
    fi
    _antenna_line_to_json_g "$1" "$2"
    printf '%s' "$_R"
}

# --- Hex-to-Decimal Cell ID Decomposition ------------------------------------
# Global-setting hex -> decimal. Sets _R and mirrors the old `printf '%d' 0x...`
# exactly: empty input -> _R="" rc 0; valid -> decimal rc 0; anything printf
# rejected (non-hex chars, or a value above 0x7FFFFFFFFFFFFFFF) -> _R="0" rc 1.
# The guard also keeps an invalid $((0x...)) from aborting the whole shell.
_hex_to_dec_g() {
    local h="$1"
    local z
    _R=""
    [ -z "$h" ] && return 0
    case $h in
        *[!0-9A-Fa-f]*) _R=0 ; return 1 ;;
    esac
    z=${h%%[!0]*}
    h=${h#"$z"}
    case $h in
        '') _R=0 ; return 0 ;;
        ?????????????????*) _R=0 ; return 1 ;;
        [89A-Fa-f]???????????????) _R=0 ; return 1 ;;
    esac
    _R=$((0x$h))
    return 0
}

# AT+QENG LTE <SINR> is not dB: per the RG520N/RM5xxN AT manual (5.20) the
# actual value is Y = 2X - 20 dB for a raw X of 0..25 (-20..+30 dB). Confirmed
# live on an RM551E against QCAINFO RSSNR and QSINR from X=8 to X=24. NR5G
# <SINR> is already dB and must not go through here. Strips a trailing CR (the
# field is the last one on the EN-DC LTE line). Anything that is not 1-2
# digits in 0..25 ("-", -32768, empty, garbage) sets _R="" so the status
# composer publishes null. Clobbers _S.
_lte_sinr_db_g() {
    local x
    _S=$1 ; _pat_del "$_PA_CR"
    x=$_S
    _R=""
    case $x in
        [0-9]|[0-9][0-9]) ;;
        *) return 0 ;;
    esac
    x=${x#0}
    [ -z "$x" ] && x=0
    [ "$x" -gt 25 ] && return 0
    _R=$((x * 2 - 20))
    return 0
}

# Converts a hex cell ID to decimal and computes eNodeB/gNodeB ID + Sector ID.
# LTE (28-bit ECI): eNodeB ID = cell_id >> 8,  Sector ID = cell_id & 0xFF
# NR  (36-bit NCI): gNodeB ID = cell_id >> 14, Sector ID = cell_id & 0x3FFF
# Sets globals: _cid_dec, _cid_enb, _cid_sec
# Args: $1=hex_cell_id, $2="nr" for NR bit-split (default: LTE)
_compute_cell_parts() {
    _cid_dec="" ; _cid_enb="" ; _cid_sec=""
    [ -z "$1" ] && return
    _hex_to_dec_g "$1" || { _cid_dec=""; return 0; }
    _cid_dec=$_R
    if [ "$2" = "nr" ]; then
        _cid_enb=$((_cid_dec / 16384))
        _cid_sec=$((_cid_dec % 16384))
    else
        _cid_enb=$((_cid_dec / 256))
        _cid_sec=$((_cid_dec % 256))
    fi
}

# Converts a hex string (e.g. TAC) to decimal. Empty input -> empty output.
_hex_to_dec() {
    local rc
    [ -z "$1" ] && return
    _hex_to_dec_g "$1"
    rc=$?
    printf '%s' "$_R"
    return $rc
}

# --- SCS Enum to kHz Mapping --------------------------------------------------
map_scs_to_khz_g() {
    case "$1" in
        0) _R=15 ;;
        1) _R=30 ;;
        2) _R=60 ;;
        3) _R=120 ;;
        4) _R=240 ;;
        *) _R="" ;;
    esac
}

map_scs_to_khz() {
    map_scs_to_khz_g "$1"
    echo "$_R"
}

# Builds the QENG csv in _S: every "+QENG: " removed (sed 's/+QENG: //g'), then
# every '"' and ' '. $2=1 also removes CRs (tr -d '\r').
_pat_qeng_csv() {
    _S=$1
    _pat_del '+QENG: '
    _pat_del '"'
    _pat_del ' '
    if [ "$2" = 1 ]; then _pat_del "$_PA_CR"; fi
    return 0
}

# -----------------------------------------------------------------------------
# Parse AT+QENG="servingcell"
# Populates: lte_state, lte_band, lte_earfcn, lte_bandwidth, lte_pci,
#            lte_rsrp, lte_rsrq, lte_sinr, lte_rssi,
#            lte_cell_id, lte_enodeb_id, lte_sector_id, lte_tac,
#            nr_state, nr_band, nr_arfcn, nr_pci, nr_rsrp, nr_rsrq, nr_sinr,
#            nr_scs, nr_cell_id, nr_enodeb_id, nr_sector_id, nr_tac,
#            network_type, service_status
#
# One pass over the reply lines, no forks. Lines are only considered when they
# start with "+QENG:". The first "servingcell" line, the first "NR5G-NSA" line
# and the first "LTE" line without "servingcell" are remembered; a trailing CR
# stays on a field unless the original pipeline stripped it (hex fields, and the
# whole NSA NR line).
# -----------------------------------------------------------------------------
parse_serving_cell() {
    local rest="$1"
    local line
    local more=1
    local have_qeng=0
    local sc_line=""
    local lte_line=""
    local nr_line=""
    local has_nsa=0
    local has_sa=0
    local has_lte=0
    local raw_hex

    # Reset all fields
    lte_state="unknown"
    nr_state="unknown"
    lte_band="" ; lte_earfcn="" ; lte_bandwidth="" ; lte_pci=""
    lte_rsrp="" ; lte_rsrq="" ; lte_sinr="" ; lte_rssi=""
    lte_cell_id="" ; lte_enodeb_id="" ; lte_sector_id="" ; lte_tac=""
    nr_band="" ; nr_arfcn="" ; nr_pci=""
    nr_rsrp="" ; nr_rsrq="" ; nr_sinr="" ; nr_scs=""
    nr_cell_id="" ; nr_enodeb_id="" ; nr_sector_id="" ; nr_tac=""

    while [ "$more" = 1 ]; do
        case $rest in
            *"$_PA_NL"*)
                line=${rest%%"$_PA_NL"*}
                rest=${rest#*"$_PA_NL"}
                ;;
            *)
                line=$rest
                rest=""
                more=0
                ;;
        esac
        case $line in
            '+QENG:'*)
                have_qeng=1
                case $line in
                    *'"servingcell"'*)
                        [ -z "$sc_line" ] && sc_line=$line
                        ;;
                esac
                case $line in
                    *'"NR5G-NSA"'*)
                        has_nsa=1
                        [ -z "$nr_line" ] && nr_line=$line
                        ;;
                esac
                case $line in
                    *'"NR5G-SA"'*) has_sa=1 ;;
                esac
                case $line in
                    *'"LTE"'*)
                        has_lte=1
                        case $line in
                            *'"servingcell"'*) ;;
                            *) [ -z "$lte_line" ] && lte_line=$line ;;
                        esac
                        ;;
                esac
                ;;
        esac
    done

    if [ "$have_qeng" = 0 ]; then
        qlog_warn "parse_serving_cell: no +QENG: lines in response"
        service_status="unknown"
        return
    fi

    # --- Detect connection state ---
    case "$sc_line" in
        *'"NOCONN"'*)  service_status="idle" ;;
        *'"LIMSRV"'*)  service_status="limited" ;;
        *'"CONNECT"'*) service_status="connected" ;;
        *'"SEARCH"'*)  service_status="searching" ;;
    esac

    # ===== EN-DC / NSA MODE =====
    if [ "$has_nsa" = 1 ]; then
        network_type="5G-NSA"

        # LTE line (separate from "servingcell" line in EN-DC)
        if [ -n "$lte_line" ]; then
            lte_state="connected"
            _pat_qeng_csv "$lte_line" 0
            _pat_split

            # LTE,is_tdd,MCC,MNC,cellID,PCID,earfcn,freq_band_ind,UL_bw,DL_bw,TAC,RSRP,RSRQ,RSSI,SINR
            # 1   2      3   4   5      6    7      8              9     10    11  12   13   14   15
            _S=$_F5 ; _pat_del "$_PA_CR" ; raw_hex=$_S
            _compute_cell_parts "$raw_hex"
            lte_cell_id="$_cid_dec" ; lte_enodeb_id="$_cid_enb" ; lte_sector_id="$_cid_sec"
            lte_pci=$_F6
            lte_earfcn=$_F7
            lte_band="B${_F8}"
            lte_bandwidth=$_F10
            _S=$_F11 ; _pat_del "$_PA_CR"
            _hex_to_dec_g "$_S" ; lte_tac=$_R
            lte_rsrp=$_F12
            lte_rsrq=$_F13
            lte_rssi=$_F14
            _lte_sinr_db_g "$_F15" ; lte_sinr=$_R
        fi

        # NR5G-NSA line
        if [ -n "$nr_line" ]; then
            nr_state="connected"
            _pat_qeng_csv "$nr_line" 1
            _pat_split

            # NR5G-NSA,MCC,MNC,PCID,RSRP,SINR,RSRQ,ARFCN,band,NR_DL_bw,scs
            # 1        2   3   4    5    6    7    8     9    10        11
            nr_pci=$_F4
            nr_rsrp=$_F5
            nr_sinr=$_F6
            nr_rsrq=$_F7
            nr_arfcn=$_F8
            nr_band="N${_F9}"
            map_scs_to_khz_g "$_F11" ; nr_scs=$_R
        fi

    # ===== SA MODE =====
    elif [ "$has_sa" = 1 ]; then
        network_type="5G-SA"
        lte_state="inactive"
        nr_state="connected"

        _pat_qeng_csv "$sc_line" 0
        _pat_split

        # servingcell,state,NR5G-SA,duplex,MCC,MNC,cellID,PCID,TAC,ARFCN,band,NR_DL_bw,RSRP,RSRQ,SINR,scs,srxlev
        # 1           2     3       4      5   6   7      8    9   10     11   12       13   14   15   16  17
        _S=$_F7 ; _pat_del "$_PA_CR" ; raw_hex=$_S
        _compute_cell_parts "$raw_hex" "nr"
        nr_cell_id="$_cid_dec" ; nr_enodeb_id="$_cid_enb" ; nr_sector_id="$_cid_sec"
        nr_pci=$_F8
        _S=$_F9 ; _pat_del "$_PA_CR"
        _hex_to_dec_g "$_S" ; nr_tac=$_R
        nr_arfcn=$_F10
        nr_band="N${_F11}"
        nr_rsrp=$_F13
        nr_rsrq=$_F14
        nr_sinr=$_F15
        map_scs_to_khz_g "$_F16" ; nr_scs=$_R

    # ===== LTE-ONLY MODE =====
    elif [ "$has_lte" = 1 ]; then
        network_type="LTE"
        nr_state="inactive"

        # LTE-only: "LTE" on the SAME line as "servingcell"
        _pat_qeng_csv "$sc_line" 0

        case "$_S" in
            *SEARCH*)
                lte_state="searching"
                return
                ;;
            *)
                lte_state="connected"
                ;;
        esac
        _pat_split

        # servingcell,state,LTE,is_tdd,MCC,MNC,cellID,PCID,earfcn,freq_band_ind,UL_bw,DL_bw,TAC,RSRP,RSRQ,RSSI,SINR,...
        # 1           2     3   4      5   6   7      8    9      10             11    12    13  14   15   16   17
        _S=$_F7 ; _pat_del "$_PA_CR" ; raw_hex=$_S
        _compute_cell_parts "$raw_hex"
        lte_cell_id="$_cid_dec" ; lte_enodeb_id="$_cid_enb" ; lte_sector_id="$_cid_sec"
        lte_pci=$_F8
        lte_earfcn=$_F9
        lte_band="B${_F10}"
        lte_bandwidth=$_F12
        _S=$_F13 ; _pat_del "$_PA_CR"
        _hex_to_dec_g "$_S" ; lte_tac=$_R
        lte_rsrp=$_F14
        lte_rsrq=$_F15
        lte_rssi=$_F16
        _lte_sinr_db_g "$_F17" ; lte_sinr=$_R

    else
        lte_state="unknown"
        nr_state="unknown"
        service_status="unknown"
    fi
}

# Original fork-heavy pipeline. Only used when a zone's temp file holds
# something other than a plain integer (never seen on real sysfs), so the awk
# semantics for odd input stay exactly the historical ones.
_parse_temperature_legacy() {
    local zone
    local ztype
    local result

    result=$(for zone in /sys/class/thermal/thermal_zone*; do
        [ -r "$zone/type" ] || continue
        [ -r "$zone/temp" ] || continue
        ztype=$(cat "$zone/type" 2>/dev/null)
        case "$ztype" in
            mdmss-*|mdmq6-*|sdr[0-9]*|xo-therm*|sys-therm-*|cpuss-*)
                cat "$zone/temp" 2>/dev/null
                ;;
        esac
    done | awk '$1 > 0' | \
        awk '{ sum += $1; count++ } END { if (count > 0) printf "%.0f", sum/1000/count; }')

    if [ -n "$result" ]; then
        t1_temperature="$result"
    else
        t1_temperature=""
    fi
}

# -----------------------------------------------------------------------------
# SoC thermal — Average temperature from /sys/class/thermal (no AT channel)
# Populates: t1_temperature
#
# Reads sysfs instead of AT+QTEMP: AT+QTEMP can crash this firmware's AT
# channel (/dev/smd11). Thermal sysfs is independent of AT and stable.
#
# Selection is by thermal-zone TYPE NAME, not zone index: indices renumber
# across firmware builds but type names are stable.
#
# Builtins only (read, no cat/awk). The mean is rounded half-to-even exactly
# like awk's printf "%.0f", sum/1000/count: with integer millidegrees the
# quotient is only ever an exact .5 when sum == 500*count*(2k+1), so integer
# round-half-even on sum/(1000*count) gives the same digits.
# -----------------------------------------------------------------------------
parse_temperature() {
    local zone
    local ztype
    local t
    local extra
    local den
    local q
    local r2
    local sum=0
    local count=0

    # --- TUNING KNOB: thermal-zone type-name allowlist (case glob) -----------
    # Modem-relevant SoC sensors plus the AP CPU cores (cpuss-*), averaged into
    # the single overall temperature. Edit this glob to tune the zone set
    # for temperature parity. sysfs temp is in millidegrees C; non-positive
    # values (e.g. -273000, -40960, empty) are unavailable sentinels and are
    # excluded below.
    # -------------------------------------------------------------------------
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -r "$zone/type" ] || continue
        [ -r "$zone/temp" ] || continue
        ztype=""
        read -r ztype < "$zone/type" 2>/dev/null
        case "$ztype" in
            mdmss-*|mdmq6-*|sdr[0-9]*|xo-therm*|sys-therm-*|cpuss-*)
                t=""
                extra=""
                { read -r t ; read -r extra ; } < "$zone/temp" 2>/dev/null
                [ -z "$extra" ] || { _parse_temperature_legacy ; return ; }
                case $t in
                    '') continue ;;
                    -*)
                        case ${t#-} in
                            ''|*[!0-9]*) _parse_temperature_legacy ; return ;;
                        esac
                        continue
                        ;;
                    *[!0-9]*) _parse_temperature_legacy ; return ;;
                    ???????????????*) _parse_temperature_legacy ; return ;;
                esac
                # plain non-negative integer: drop leading zeros (no octal), skip 0
                t=${t#"${t%%[!0]*}"}
                [ -n "$t" ] || continue
                sum=$((sum + t))
                count=$((count + 1))
                ;;
        esac
    done

    if [ "$count" -eq 0 ]; then
        t1_temperature=""
        return
    fi

    den=$((count * 1000))
    q=$((sum / den))
    r2=$((sum % den * 2))
    if [ "$r2" -gt "$den" ]; then
        q=$((q + 1))
    elif [ "$r2" -eq "$den" ] && [ $((q % 2)) -eq 1 ]; then
        q=$((q + 1))
    fi
    t1_temperature="$q"
}

# -----------------------------------------------------------------------------
# Parse AT+COPS?
# Populates: t2_carrier
# -----------------------------------------------------------------------------
parse_carrier() {
    _pat_first_line "$1" '+COPS:'

    if [ -z "$_pat_line" ]; then
        t2_carrier=""
        return
    fi

    # Strip prefix and CR: "0,0,"Smart",7" or just "2" when deregistered
    _S=$_pat_line
    _pat_del '+COPS: '
    _pat_del "$_PA_CR"

    # Need at least 3 comma-separated fields for operator name
    case $_S in
        *,*,*) ;;
        *)
            t2_carrier=""
            return
            ;;
    esac

    _S=${_S#*,}
    _S=${_S#*,}
    _S=${_S%%,*}
    _pat_del '"'
    t2_carrier=$_S
}

# -----------------------------------------------------------------------------
# Parse AT+CPIN?
# Populates: t2_sim_status
# -----------------------------------------------------------------------------
parse_sim_status() {
    local raw="$1"

    case "$raw" in
        *"READY"*)         t2_sim_status="ready" ;;
        *"SIM PIN"*)       t2_sim_status="pin_required" ;;
        *"SIM PUK"*)       t2_sim_status="puk_required" ;;
        *"NOT INSERTED"*|*"NOT READY"*) t2_sim_status="not_inserted" ;;
        *ERROR*)           t2_sim_status="error" ;;
        *)                 t2_sim_status="unknown" ;;
    esac
}

# -----------------------------------------------------------------------------
# Parse AT+QUIMSLOT?
# Populates: t2_sim_slot
# -----------------------------------------------------------------------------
parse_sim_slot() {
    _pat_first_line "$1" '+QUIMSLOT:'

    if [ -n "$_pat_line" ]; then
        _S=$_pat_line
        _pat_del '+QUIMSLOT: '
        _pat_del ' '
        _pat_del "$_PA_CR"
        t2_sim_slot=$_S
    fi
}

# -----------------------------------------------------------------------------
# Parse AT+CVERSION (Boot-only)
# Populates: boot_firmware, boot_build_date, boot_manufacturer
# -----------------------------------------------------------------------------
parse_version() {
    local raw="$1"

    boot_firmware=$(printf '%s\n' "$raw" | grep '^VERSION:' | sed 's/VERSION: //g' | tr -d '\r')
    boot_build_date=$(printf '%s\n' "$raw" | grep -E '^[A-Z][a-z]{2} +[0-9]' | head -1 | awk '{print $1, $2, $3}' | tr -d '\r')
    boot_manufacturer=$(printf '%s\n' "$raw" | grep '^Authors:' | sed 's/Authors: //g' | tr -d '\r')
}

# -----------------------------------------------------------------------------
# Parse AT+QGETCAPABILITY (Boot-only)
# Populates: boot_lte_category
# -----------------------------------------------------------------------------
parse_capability() {
    local raw="$1"

    local cat_line
    cat_line=$(printf '%s\n' "$raw" | grep '+QGETCAPABILITY: LTE-CATEGORY:' | head -1)

    if [ -n "$cat_line" ]; then
        boot_lte_category=$(printf '%s' "$cat_line" | sed 's/+QGETCAPABILITY: LTE-CATEGORY://g' | tr -d ' \r')
    fi
}

# -----------------------------------------------------------------------------
# Parse AT+QNWCFG="lte_mimo_layers" / "nr_mimo_layers" (Tier 2)
# Args: $1 = LTE mimo response, $2 = NR mimo response (optional)
# Populates: t2_mimo
# -----------------------------------------------------------------------------
parse_mimo() {
    local lte_raw="$1"
    local nr_raw="$2"

    local lte_part=""
    local nr_part=""

    # LTE MIMO: +QNWCFG: "lte_mimo_layers",<ul>,<dl>
    local lte_line
    lte_line=$(printf '%s\n' "$lte_raw" | grep '+QNWCFG: "lte_mimo_layers"' | head -1)
    if [ -n "$lte_line" ]; then
        local csv
        csv=$(printf '%s' "$lte_line" | sed 's/+QNWCFG: "lte_mimo_layers",//g' | tr -d ' \r')
        local ul_mimo dl_mimo
        ul_mimo=$(printf '%s' "$csv" | cut -d',' -f1)
        dl_mimo=$(printf '%s' "$csv" | cut -d',' -f2)
        if [ -n "$ul_mimo" ] && [ -n "$dl_mimo" ]; then
            lte_part="LTE ${ul_mimo}x${dl_mimo}"
        fi
    fi

    # NR MIMO: +QNWCFG: "nr5g_mimo_layers",<ul>,<dl>
    if [ -n "$nr_raw" ]; then
        local nr_line
        nr_line=$(printf '%s\n' "$nr_raw" | grep '+QNWCFG: "nr5g_mimo_layers"' | head -1)
        if [ -n "$nr_line" ]; then
            local csv
            csv=$(printf '%s' "$nr_line" | sed 's/+QNWCFG: "nr5g_mimo_layers",//g' | tr -d ' \r')
            local ul_mimo dl_mimo
            ul_mimo=$(printf '%s' "$csv" | cut -d',' -f1)
            dl_mimo=$(printf '%s' "$csv" | cut -d',' -f2)
            if [ -n "$ul_mimo" ] && [ -n "$dl_mimo" ]; then
                nr_part="NR ${ul_mimo}x${dl_mimo}"
            fi
        fi
    fi

    # Combine: "LTE 1x4 | NR 2x4" or just "LTE 1x4"
    if [ -n "$lte_part" ] && [ -n "$nr_part" ]; then
        t2_mimo="${lte_part} | ${nr_part}"
    elif [ -n "$lte_part" ]; then
        t2_mimo="$lte_part"
    elif [ -n "$nr_part" ]; then
        t2_mimo="$nr_part"
    fi
}

# --- LTE Resource Blocks → MHz Mapping ----------------------------------------
# QCAINFO uses resource block counts for LTE bandwidth, not the enum used by
# AT+QENG. Mapping per 3GPP 36.101 Table 5.6-1.
_lte_rb_to_mhz_g() {
    case "$1" in
        6)   _R=1 ;;    # 1.4 MHz — round to 1 for integer math
        15)  _R=3 ;;
        25)  _R=5 ;;
        50)  _R=10 ;;
        75)  _R=15 ;;
        100) _R=20 ;;
        *)   _R=0 ;;
    esac
}

_lte_rb_to_mhz() {
    _lte_rb_to_mhz_g "$1"
    echo "$_R"
}

# --- NR Bandwidth Enum → MHz Mapping ------------------------------------------
# Same enum as AT+QENG NR_DL_bandwidth. Mapping per 3GPP 38.101.
_nr_bw_to_mhz_g() {
    case "$1" in
        0)  _R=5 ;;
        1)  _R=10 ;;
        2)  _R=15 ;;
        3)  _R=20 ;;
        4)  _R=25 ;;
        5)  _R=30 ;;
        6)  _R=40 ;;
        7)  _R=50 ;;
        8)  _R=60 ;;
        9)  _R=70 ;;
        10) _R=80 ;;
        11) _R=90 ;;
        12) _R=100 ;;
        13) _R=200 ;;
        14) _R=400 ;;
        15) _R=35 ;;
        16) _R=45 ;;
        *)  _R=0 ;;
    esac
}

_nr_bw_to_mhz() {
    _nr_bw_to_mhz_g "$1"
    echo "$_R"
}

# -----------------------------------------------------------------------------
# Parse AT+QCAINFO (Tier 2) — Carrier Aggregation status + bandwidth +
#   per-carrier component details
# Populates: t2_ca_active, t2_ca_count, t2_nr_ca_active, t2_nr_ca_count,
#            t2_total_bandwidth_mhz, t2_bandwidth_details,
#            t2_carrier_components (JSON array string)
#
# Per-carrier component output (JSON array):
#   [{"type":"PCC","technology":"LTE","band":"B3","earfcn":1350,
#     "bandwidth_mhz":15,"pci":135,"rsrp":-115,"rsrq":-15,
#     "rssi":-82,"sinr":5}, ...]
#
# AT+QCAINFO response formats (all fields after stripping +QCAINFO: and quotes/spaces):
#
# LTE PCC/SCC: type,freq,bw_rb,LTEBAND<N>,state,PCI,RSRP,RSRQ,RSSI,RSSNR[,...]
#   Positions:  1    2    3     4          5     6   7    8    9    10
#
# NR short (PCC or old SCC): type,freq,bw_enum,NR5GBAND<N>,PCI[,RSRP,RSRQ[,SNR]]
#   Positions:                1    2    3       4           5  6    7     8
#   Total fields: 5-8
#
# NR long (SCC with UL info): type,freq,bw_enum,NR5GBAND<N>,state,PCI,UL_cfg,UL_bw,UL_ARFCN[,RSRP,RSRQ[,SNR]]
#   Positions:                 1    2    3       4           5     6   7      8     9       10   11    12
#   Total fields: 9-12
#
# NR_SNR conversion: actual_dB = raw_value / 100 (3GPP)
# -----------------------------------------------------------------------------
parse_ca_info() {
    # One awk pass over the reply (no tmp files, no jq, no eval). The awk
    # prints exactly six lines, one value each, in this fixed order:
    #   1  lte_scc_count  lines containing +QCAINFO: "SCC" and LTE BAND (raw text)
    #   2  nr_scc_count   lines containing +QCAINFO: "SCC" and NR (raw text)
    #   3  state          E = no ^+QCAINFO: line (early return), else nr_pcc_seen 0/1
    #   4  total_mhz      (lines 4-6 are omitted when state is E)
    #   5  details        "B3: 15 MHz + N78: 100 MHz"
    #   6  components     compact JSON array, or empty when the old jq
    #                     tonumber would have failed (old output was "")
    # Every value is single-line: CR is stripped, LF cannot occur inside a
    # record, and JSON strings are escaped (\\, \", control chars as \u00XX).
    local _pca_out
    local _pca_lte
    local _pca_nr
    local _pca_state
    local _pca_total
    local _pca_details
    local _pca_cc

    _pca_out=$(awk '
function js(s,    o, i, n, c) {
    o = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c in ESC) o = o ESC[c]; else o = o c
    }
    return "\"" o "\""
}
# jq tonumber on a string, rendered like jq -c. Sets bad=1 where jq errors.
function num(s,    c, sg, b, lc, n, i, nd, m, v, p, t, ep, d, e, ae, dp, out) {
    if (s == "") { bad = 1; return "" }
    c = substr(s, 1, 1)
    if (c == "t" || c == "f" || c == "n") { bad = 1; return "" }
    sg = ""
    b = s
    if (c == "+" || c == "-") { if (c == "-") sg = "-"; b = substr(s, 2) }
    lc = tolower(b)
    if (lc == "inf" || lc == "infinity") return sg DMAXS
    if (lc == "nan") return "null"
    n = length(b)
    i = 1
    nd = 0
    while (i <= n && index(DIG, substr(b, i, 1))) { i++; nd++ }
    if (i <= n && substr(b, i, 1) == ".") {
        i++
        while (i <= n && index(DIG, substr(b, i, 1))) { i++; nd++ }
    }
    if (nd == 0) { bad = 1; return "" }
    if (i <= n && (substr(b, i, 1) == "e" || substr(b, i, 1) == "E")) {
        i++
        if (i <= n && (substr(b, i, 1) == "+" || substr(b, i, 1) == "-")) i++
        m = 0
        while (i <= n && index(DIG, substr(b, i, 1))) { i++; m++ }
        if (m == 0) { bad = 1; return "" }
    }
    if (i <= n) { bad = 1; return "" }
    # Strip leading zeros so busybox awk never takes its octal/hex path.
    sub(/^0+/, "", b)
    c = substr(b, 1, 1)
    if (c == "" || c == "." || c == "e" || c == "E") b = "0" b
    v = (sg b) + 0
    if (v == 0) return (sg == "-") ? "-0" : "0"
    if (v > DMAXN || v < -DMAXN) return sg DMAXS
    # Shortest round-trip digits, then jq dtoa layout.
    for (p = 0; p < 17; p++) {
        t = sprintf("%." p "e", v)
        if (t + 0 == v) break
    }
    if (substr(t, 1, 1) == "-") t = substr(t, 2)
    ep = index(t, "e")
    d = substr(t, 1, ep - 1)
    e = substr(t, ep + 1) + 0
    sub(/\./, "", d)
    sub(/0+$/, "", d)
    nd = length(d)
    dp = e + 1
    if (dp <= -4 || dp > nd + 15) {
        out = substr(d, 1, 1)
        if (nd > 1) out = out "." substr(d, 2)
        ae = (e < 0) ? -e : e
        out = out "e" ((e < 0) ? "-" : "+") ((ae < 10) ? "0" ae : ae)
    } else if (dp <= 0) {
        out = "0."
        for (i = 0; i < -dp; i++) out = out "0"
        out = out d
    } else if (dp >= nd) {
        out = d
        for (i = nd; i < dp; i++) out = out "0"
    } else {
        out = substr(d, 1, dp) "." substr(d, dp + 1)
    }
    return ((v < 0) ? "-" : "") out
}
function nn(s) { return (s == "null") ? "null" : num(s) }
function sane(s,    i, n) {
    if (s == "" || s == "-") return "null"
    n = length(s)
    for (i = 1; i <= n; i++) if (!index(DIGD, substr(s, i, 1))) return "null"
    return s
}
# Old: case -32768 -> null; else printf %s | awk {if($1+0==$1) ...}
function nrsnr(r,    o) {
    if (r == "-32768") return "null"
    if (r == "") return ""
    $0 = r
    # Blank-only field (tabs): the old fresh awk saw an unset $1, which
    # compares equal to 0. A reused $1 keeps stale flags, so pin it.
    if (NF == 0) return "0.0"
    if ($1+0==$1) o = sprintf("%.1f", $1/100); else o = "null"
    return o
}
BEGIN {
    DIG = "0123456789"
    DIGD = "0123456789-"
    DMAXS = "1.7976931348623157e+308"
    DMAXN = 1.7976931348623157e308
    L["6"] = 1; L["15"] = 3; L["25"] = 5; L["50"] = 10; L["75"] = 15; L["100"] = 20
    N["0"] = 5; N["1"] = 10; N["2"] = 15; N["3"] = 20; N["4"] = 25; N["5"] = 30
    N["6"] = 40; N["7"] = 50; N["8"] = 60; N["9"] = 70; N["10"] = 80; N["11"] = 90
    N["12"] = 100; N["13"] = 200; N["14"] = 400; N["15"] = 35; N["16"] = 45
    for (i = 1; i < 32; i++) ESC[sprintf("%c", i)] = sprintf("\\u%04x", i)
    ESC[sprintf("%c", 127)] = "\\u007f"
    ESC["\\"] = "\\\\"
    ESC["\""] = "\\\""
    lsc = 0; nsc = 0; seen = 0; pcc = 0; tot = 0; det = ""; arr = ""; bad = 0
}
{
    ln = $0 ""
    if (index(ln, "+QCAINFO: \"SCC\"")) {
        if (index(ln, "LTE BAND")) lsc++
        if (index(ln, "NR")) nsc++
    }
    if (substr(ln, 1, 9) != "+QCAINFO:") next
    seen = 1
    csv = ln
    gsub(/\+QCAINFO: /, "", csv)
    gsub(/"/, "", csv)
    gsub(/ /, "", csv)
    gsub("\r", "", csv)
    # cut -d, -fN returns the whole line when it has no comma.
    if (index(csv, ",")) {
        nf = split(csv, f, ",")
        for (i = 1; i <= 12; i++) f[i] = (i <= nf) ? f[i] "" : ""
    } else {
        nf = 1
        for (i = 1; i <= 12; i++) f[i] = csv
    }
    typ = f[1]; frq = f[2]; bw = f[3]; bs = f[4]
    pci = "null"; rsrp = "null"; rsrq = "null"; rssi = "null"; snr = "null"
    if (substr(bs, 1, 7) == "LTEBAND") {
        tech = "LTE"
        mhz = (bw in L) ? L[bw] : 0
        num_ = bs; sub(/LTEBAND/, "", num_); band = "B" num_
        pci = f[6]; rsrp = f[7]; rsrq = f[8]; rssi = f[9]; snr = f[10]
    } else if (substr(bs, 1, 8) == "NR5GBAND" || substr(bs, 1, 8) == "NRDCBAND") {
        tech = "NR"
        mhz = (bw in N) ? N[bw] : 0
        num_ = bs; sub(/NR5GBAND/, "", num_); sub(/NRDCBAND/, "", num_); band = "N" num_
        if (nf >= 9) {
            pci = f[6]
            if (nf >= 10) rsrp = f[10]
            if (nf >= 11) rsrq = f[11]
            if (nf >= 12) snr = nrsnr(f[12])
        } else {
            pci = f[5]
            if (nf >= 6) rsrp = f[6]
            if (nf >= 7) rsrq = f[7]
            if (nf >= 8) snr = nrsnr(f[8])
        }
    } else {
        next
    }
    if (mhz > 0) {
        tot += mhz
        det = (det == "") ? band ": " mhz " MHz" : det " + " band ": " mhz " MHz"
    }
    pci = sane(pci); rsrp = sane(rsrp); rsrq = sane(rsrq); rssi = sane(rssi)
    if (snr == "" || snr == "-") snr = "null"
    if (typ == "PCC" && tech == "NR") pcc = 1
    # Same tab-joined record the old code fed to jq -Rs split("\t"), so a
    # tab inside a modem field shifts columns exactly as before.
    rec = typ "\t" tech "\t" band "\t" ((frq == "") ? "null" : frq) "\t" mhz "\t" pci "\t" rsrp "\t" rsrq "\t" rssi "\t" snr
    split(rec, cc, "\t")
    o = "{\"type\":" js(cc[1]) ",\"technology\":" js(cc[2]) ",\"band\":" js(cc[3])
    o = o ",\"earfcn\":" nn(cc[4]) ",\"bandwidth_mhz\":" num(cc[5])
    o = o ",\"pci\":" nn(cc[6]) ",\"rsrp\":" nn(cc[7]) ",\"rsrq\":" nn(cc[8])
    o = o ",\"rssi\":" nn(cc[9]) ",\"sinr\":" nn(cc[10]) "}"
    arr = (arr == "") ? o : arr "," o
}
END {
    print lsc
    print nsc
    if (!seen) {
        print "E"
    } else {
        print pcc
        print tot
        print det
        if (bad) print ""; else print "[" arr "]"
    }
}' <<_PCA_EOF
$1
_PCA_EOF
)

    {
        IFS= read -r _pca_lte
        IFS= read -r _pca_nr
        IFS= read -r _pca_state
        IFS= read -r _pca_total
        IFS= read -r _pca_details
        IFS= read -r _pca_cc
    } <<_PCA_EOF
$_pca_out
_PCA_EOF

    case "$_pca_lte" in ''|*[!0-9]*) _pca_lte=0 ;; esac
    case "$_pca_nr" in ''|*[!0-9]*) _pca_nr=0 ;; esac

    # --- CA counts ---
    if [ "$_pca_lte" -gt 0 ]; then
        t2_ca_active=true
        t2_ca_count=$_pca_lte
    else
        t2_ca_active=false
        t2_ca_count=0
    fi

    if [ "$_pca_nr" -gt 0 ]; then
        # In NSA mode, the first NR SCC is the NR leg itself (LTE is PCC).
        # True NR CA only when there are 2+ NR SCCs.
        if [ "$network_type" = "5G-NSA" ]; then
            if [ "$_pca_nr" -gt 1 ]; then
                t2_nr_ca_active=true
                t2_nr_ca_count=$((_pca_nr - 1))
            else
                t2_nr_ca_active=false
                t2_nr_ca_count=0
            fi
        else
            t2_nr_ca_active=true
            t2_nr_ca_count=$_pca_nr
        fi
    else
        t2_nr_ca_active=false
        t2_nr_ca_count=0
    fi

    # No +QCAINFO: line at all (or awk failed).
    case "$_pca_state" in
        0|1) ;;
        *)
            t2_total_bandwidth_mhz=0
            t2_bandwidth_details=""
            t2_carrier_components="[]"
            return
            ;;
    esac

    t2_total_bandwidth_mhz=$_pca_total
    t2_bandwidth_details="$_pca_details"
    t2_carrier_components="$_pca_cc"

    # --- Reconcile network_type from QCAINFO NR PCC ---
    # QENG may transiently report LTE after a CFUN reset while QCAINFO already
    # shows NR5G as the PCC. If we saw an NR PCC and network_type is not already
    # NR, upgrade the state so the frontend renders the correct NR card.
    if [ "$_pca_state" = "1" ]; then
        case "$network_type" in
            "5G-SA"|"5G-NSA")
                # Already NR — nothing to do
                ;;
            *)
                qlog_warn "parse_ca_info: network_type reconciled ${network_type}→5G-SA based on NR PCC in QCAINFO"
                network_type="5G-SA"
                case "$nr_state" in
                    "unknown"|"inactive") nr_state="connected" ;;
                esac
                case "$lte_state" in
                    "unknown") lte_state="inactive" ;;
                esac
                ;;
        esac
    fi
}

# -----------------------------------------------------------------------------
# Parse AT+QNWCFG="lte_time_advance" and "nr_time_advance" (Tier 2)
# Populates: lte_ta, nr_ta
# -----------------------------------------------------------------------------
parse_time_advance() {
    local raw="$1"

    # LTE TA: +QNWCFG: "lte_time_advance",<enabled>,<ta>
    # The enable reply is +QNWCFG: "lte_time_advance",1 (2 fields); the query
    # reply adds <ta>. We want the reply line with 3+ fields.
    # Anchor on the reply prefix; qcmd's echoed AT+QNWCFG line also names the key.
    local lte_ta_line
    lte_ta_line=$(printf '%s\n' "$raw" | awk -F',' 'index($0,"+QNWCFG:")==1 && index($0,"\"lte_time_advance\"") && NF>=3 {print; exit}')

    if [ -n "$lte_ta_line" ]; then
        local ta_val
        ta_val=$(printf '%s' "$lte_ta_line" | tr -d '"' | tr -d ' ' | tr -d '\r' | awk -F',' '{print $3}')
        case "$ta_val" in
            *[!0-9-]*|'') lte_ta="" ;;
            *) lte_ta="$ta_val" ;;
        esac
    fi

    # NR TA: +QNWCFG: "nr5g_time_advance",<enabled>,<nta>,<extra>
    # Response has 4 fields — TA value is field 3, NOT last field
    local nr_ta_line
    # Anchor on the reply prefix; qcmd's echoed AT+QNWCFG line also names the key.
    nr_ta_line=$(printf '%s\n' "$raw" | awk -F',' 'index($0,"+QNWCFG:")==1 && index($0,"\"nr5g_time_advance\"") && NF>=3 {print; exit}')

    if [ -n "$nr_ta_line" ]; then
        local nta_val
        nta_val=$(printf '%s' "$nr_ta_line" | tr -d '"' | tr -d ' ' | tr -d '\r' | awk -F',' '{print $3}')
        case "$nta_val" in
            *[!0-9-]*|'') nr_ta="" ;;
            *) nr_ta="$nta_val" ;;
        esac
    fi
}

# =============================================================================
# PER-ANTENNA SIGNAL PARSERS (Tier 1.5)
# =============================================================================
# AT+QRSRP, AT+QRSRQ, AT+QSINR each return per-antenna-port values.
# Format: +Q<CMD>: <ant0>,<ant1>,<ant2>,<ant3>,<RAT>
# In EN-DC mode, two lines are returned (one LTE, one NR5G).
# Sentinel value -32768 indicates inactive/unavailable antenna port.

# One pass over a compound reply: sets _pat_l to the first line holding
# "+<tag>:" followed later by "LTE" (grep '+TAG:.*LTE') and _pat_n to the first
# one followed later by "NR5G" (grep '+TAG:.*NR5G'). $1=raw, $2=tag.
_pat_antenna_lines() {
    local rest="$1"
    local key="+$2:"
    local line
    local tail
    local more=1
    _pat_l=""
    _pat_n=""
    while [ "$more" = 1 ]; do
        case $rest in
            *"$_PA_NL"*)
                line=${rest%%"$_PA_NL"*}
                rest=${rest#*"$_PA_NL"}
                ;;
            *)
                line=$rest
                rest=""
                more=0
                ;;
        esac
        case $line in
            *"$key"*)
                tail=${line#*"$key"}
                case $tail in
                    *LTE*) [ -z "$_pat_l" ] && _pat_l=$line ;;
                esac
                case $tail in
                    *NR5G*) [ -z "$_pat_n" ] && _pat_n=$line ;;
                esac
                if [ -n "$_pat_l" ] && [ -n "$_pat_n" ]; then return 0; fi
                ;;
        esac
    done
    return 0
}

# -----------------------------------------------------------------------------
# Parse AT+QRSRP — Per-antenna RSRP
# Populates: sig_lte_rsrp, sig_nr_rsrp (JSON array strings)
# -----------------------------------------------------------------------------
parse_qrsrp() {
    _pat_antenna_lines "$1" QRSRP
    _antenna_line_to_json_g "$_pat_l" "QRSRP" ; sig_lte_rsrp=$_R
    _antenna_line_to_json_g "$_pat_n" "QRSRP" ; sig_nr_rsrp=$_R
}

# -----------------------------------------------------------------------------
# Parse AT+QRSRQ — Per-antenna RSRQ
# Populates: sig_lte_rsrq, sig_nr_rsrq (JSON array strings)
# -----------------------------------------------------------------------------
parse_qrsrq() {
    _pat_antenna_lines "$1" QRSRQ
    _antenna_line_to_json_g "$_pat_l" "QRSRQ" ; sig_lte_rsrq=$_R
    _antenna_line_to_json_g "$_pat_n" "QRSRQ" ; sig_nr_rsrq=$_R
}

# -----------------------------------------------------------------------------
# Parse AT+QSINR — Per-antenna SINR
# Populates: sig_lte_sinr, sig_nr_sinr (JSON array strings)
# -----------------------------------------------------------------------------
parse_qsinr() {
    _pat_antenna_lines "$1" QSINR
    _antenna_line_to_json_g "$_pat_l" "QSINR" ; sig_lte_sinr=$_R
    _antenna_line_to_json_g "$_pat_n" "QSINR" ; sig_nr_sinr=$_R
}

# =============================================================================
# CELLULAR INFORMATION PARSERS (Tier 2)
# =============================================================================

# Returns 0 when value looks like IPv6 in either colon form or Quectel's
# dotted-decimal 16-octet form.
_is_ipv6_like_addr() {
    local v="$1"
    case "$v" in
        *:*) return 0 ;;
        *[!0-9.]*|"") return 1 ;;
    esac

    [ "$(printf '%s' "$v" | awk -F'.' '{print NF}')" -eq 16 ]
}

# Prefer IPv6 DNS when available (UI compresses dotted-decimal IPv6 nicely).
_pick_preferred_dns() {
    local ipv4="$1" ipv6="$2"
    if _is_ipv6_like_addr "$ipv6"; then
        printf '%s' "$ipv6"
    elif [ -n "$ipv4" ]; then
        printf '%s' "$ipv4"
    else
        printf '%s' "$ipv6"
    fi
}

# Returns the WAN-active PDP CID by inspecting the +QMAP: "WWAN" lines in the
# same compound AT response that carries +CGCONTRDP. Picks the first QMAP line
# whose IP is non-zero. Falls back to "1" if no QMAP block is present or all
# entries are zero — matches the apn.sh CGI fallback behavior.
_cgcontrdp_active_cid() {
    local raw="$1"
    local cid
    cid=$(printf '%s\n' "$raw" | awk -F',' '
        /^\+QMAP: "WWAN"/ {
            ip = $5
            gsub(/"/, "", ip)
            gsub(/[[:space:]]/, "", ip)
            if (ip == "" || ip == "0.0.0.0" || ip == "0:0:0:0:0:0:0:0") next
            cid = $3
            gsub(/[^0-9]/, "", cid)
            if (cid != "") { print cid; exit }
        }
    ')
    [ -z "$cid" ] && cid="1"
    printf '%s' "$cid"
}

# -----------------------------------------------------------------------------
# Parse AT+CGCONTRDP — APN name and DNS servers
# Uses the WAN-active PDP context. The caller passes it as the optional second
# argument (the data CID resolved by data_cid.sh); without it the CID falls back
# to the +QMAP "WWAN" mux_id, then to 1 (legacy behaviour, QMAP firmwares only).
#
# 3GPP TS 27.007 field positions (fixed, whatever the quoting):
#   +CGCONTRDP: <cid>,<bearer_id>,<apn>,<local_addr[ mask]>,<gw_addr>,
#               <dns_prim>,<dns_sec>,<p_cscf_prim>,<p_cscf_sec>,...
# Parsed by COMMA, never by quote: the gateway is bare on one record and
# quoted on the next, and some firmwares quote nothing at all, so counting
# quoted tokens shifts every later field (a quoted gateway read as DNS, an
# IMS record's P-CSCF addresses read as DNS). No field can contain a comma
# (APNs are DNS labels, 3GPP IPv6 is dotted-decimal). Quotes are stripped per
# field. A dual-stack DNS field may carry an adjacent v4/v6 pair
# ("<v4>" "<v6>"); each token is classified by octet count (4 = IPv4,
# 16 = IPv6, colon-hex as a fallback).
#
# Example (active CID determined from +QMAP "WWAN" mux_id, not by APN string):
#   +CGCONTRDP: 1,5,"SMARTBRO","10.110.61.83",,"10.151.151.44","10.151.151.48"
#   +CGCONTRDP: 2,6,"ims","36.4.216.0...",...
#   +QMAP: "WWAN",1,1,"IPV4","10.110.61.83"  <- mux=1 -> use CGCONTRDP cid=1
#
# Populates: t2_apn, t2_primary_dns, t2_secondary_dns,
#            t2_primary_dns_v4, t2_primary_dns_v6,
#            t2_secondary_dns_v4, t2_secondary_dns_v6
# -----------------------------------------------------------------------------

# _cgcontrdp_dns_split <field>
# Prints "<v4>|<v6>" for the one or two addresses in a DNS field (first of
# each family wins; anything that is not an address is dropped).
_cgcontrdp_dns_split() {
    local tok v4="" v6=""
    for tok in $1; do
        if _is_ipv6_like_addr "$tok"; then
            [ -n "$v6" ] || v6="$tok"
        else
            case "$tok" in
                *[!0-9.]*) ;;
                *.*.*.*) [ -n "$v4" ] || v4="$tok" ;;
            esac
        fi
    done
    printf '%s|%s' "$v4" "$v6"
}

parse_cgcontrdp() {
    local raw="$1"
    local want_cid="$2"

    t2_apn=""
    t2_primary_dns=""
    t2_secondary_dns=""
    t2_primary_dns_v4=""
    t2_primary_dns_v6=""
    t2_secondary_dns_v4=""
    t2_secondary_dns_v6=""

    # Split CR-glued records onto their own lines first, so a bare-CR join
    # cannot hide (or merge into) the active CID's record.
    local normalized active_cid data_line
    normalized=$(printf '%s' "$raw" | tr '\r' '\n' | sed '/^$/d')

    # WAN-active PDP CID: the caller's (numeric) choice, else via +QMAP / default 1.
    case "$want_cid" in
        ''|*[!0-9]*) active_cid=$(_cgcontrdp_active_cid "$normalized") ;;
        *)           active_cid="$want_cid" ;;
    esac
    data_line=$(printf '%s\n' "$normalized" | grep "^+CGCONTRDP: *${active_cid}," | head -1)

    if [ -z "$data_line" ]; then
        qlog_debug "parse_cgcontrdp: no CGCONTRDP line found for active CID $active_cid"
        return
    fi

    # "apn|dns_prim|dns_sec": fields 3, 6 and 7, quotes stripped, inner
    # whitespace collapsed to one space.
    local fields dns1 dns2 pair
    fields=$(printf '%s\n' "$data_line" | awk '
        function clean(v) {
            gsub(/"/, "", v)
            gsub(/[ \t]+/, " ", v)
            gsub(/^ | $/, "", v)
            return v
        }
        # DNS fields keep address characters only, so the unquoted word
        # split in _cgcontrdp_dns_split can never glob.
        function addrs(v) {
            v = clean(v)
            gsub(/[^0-9A-Fa-f.: ]/, "", v)
            return v
        }
        {
            line = $0
            sub(/^\+CGCONTRDP:[ \t]*/, "", line)
            n = split(line, f, ",")
            print clean(f[3]) "|" addrs(n >= 6 ? f[6] : "") "|" addrs(n >= 7 ? f[7] : "")
        }')

    t2_apn="${fields%%|*}"
    fields="${fields#*|}"
    dns1="${fields%%|*}"
    dns2="${fields#*|}"

    pair=$(_cgcontrdp_dns_split "$dns1")
    t2_primary_dns_v4="${pair%%|*}"
    t2_primary_dns_v6="${pair#*|}"
    pair=$(_cgcontrdp_dns_split "$dns2")
    t2_secondary_dns_v4="${pair%%|*}"
    t2_secondary_dns_v6="${pair#*|}"

    t2_primary_dns=$(_pick_preferred_dns "$t2_primary_dns_v4" "$t2_primary_dns_v6")
    t2_secondary_dns=$(_pick_preferred_dns "$t2_secondary_dns_v4" "$t2_secondary_dns_v6")
}

# -----------------------------------------------------------------------------
# Parse AT+QMAP="WWAN" — WAN IPv4 and IPv6 addresses
#
# Response format:
#   +QMAP: "WWAN",<connected>,<mux_id>,"IPV4","<ipv4_addr>"
#   +QMAP: "WWAN",<connected>,<mux_id>,"IPV6","<ipv6_addr>"
# Example:
#   +QMAP: "WWAN",1,1,"IPV4","10.110.61.83"
#   +QMAP: "WWAN",0,1,"IPV6","0:0:0:0:0:0:0:0"
#
# IPv6 "0:0:0:0:0:0:0:0" (all zeros) means no IPv6 assigned.
#
# Populates: t2_wan_ipv4, t2_wan_ipv6
# -----------------------------------------------------------------------------
parse_wan_ip() {
    local raw="$1"

    t2_wan_ipv4=""
    t2_wan_ipv6=""

    # IPv4 line
    local ipv4_line
    ipv4_line=$(printf '%s\n' "$raw" | grep '+QMAP:' | grep '"IPV4"' | head -1)

    if [ -n "$ipv4_line" ]; then
        local csv
        csv=$(printf '%s' "$ipv4_line" | sed 's/+QMAP: //g' | tr -d '\r')
        t2_wan_ipv4=$(printf '%s' "$csv" | cut -d',' -f5 | tr -d '"' | tr -d ' ')
    fi

    # IPv6 line
    local ipv6_line
    ipv6_line=$(printf '%s\n' "$raw" | grep '+QMAP:' | grep '"IPV6"' | head -1)

    if [ -n "$ipv6_line" ]; then
        local csv
        csv=$(printf '%s' "$ipv6_line" | sed 's/+QMAP: //g' | tr -d '\r')
        local ipv6_val
        ipv6_val=$(printf '%s' "$csv" | cut -d',' -f5 | tr -d '"' | tr -d ' ')

        # All-zeros means no IPv6 assigned
        case "$ipv6_val" in
            0:0:0:0:0:0:0:0|::|0::0|'') t2_wan_ipv6="" ;;
            *) t2_wan_ipv6="$ipv6_val" ;;
        esac
    fi
}

# =============================================================================
# BAND SUPPORT: AT+QNWPREFCFG="policy_band" (Boot-only)
# =============================================================================
# Parses the modem's hardware-supported band lists.
# Response format:
#   +QNWPREFCFG: "gw_band",1:2:4:5:6:8:19
#   +QNWPREFCFG: "lte_band",1:2:3:4:5:7:8:12:...
#   +QNWPREFCFG: "nsa_nr5g_band",1:2:3:5:7:8:...
#   +QNWPREFCFG: "nr5g_band",1:2:3:5:7:8:...
#   +QNWPREFCFG: "nrdc_nr5g_band",1:2:3:5:7:8:...
#
# Sets: boot_supported_lte_bands, boot_supported_nsa_nr5g_bands,
#        boot_supported_sa_nr5g_bands, boot_supported_nrdc_nr5g_bands
#        (colon-delimited strings)

parse_policy_band() {
    local raw="$1"

    boot_supported_lte_bands=""
    boot_supported_nsa_nr5g_bands=""
    boot_supported_sa_nr5g_bands=""
    boot_supported_nrdc_nr5g_bands=""

    # Extract colon-delimited band list after the key name for each type.
    # Format per line: +QNWPREFCFG: "<key>",<bands>
    local line

    line=$(printf '%s\n' "$raw" | grep '"lte_band"' | head -1)
    if [ -n "$line" ]; then
        boot_supported_lte_bands=$(printf '%s' "$line" | sed 's/.*"lte_band",//' | tr -d '\r ')
    fi

    line=$(printf '%s\n' "$raw" | grep '"nsa_nr5g_band"' | head -1)
    if [ -n "$line" ]; then
        boot_supported_nsa_nr5g_bands=$(printf '%s' "$line" | sed 's/.*"nsa_nr5g_band",//' | tr -d '\r ')
    fi

    # grep -v excludes nsa_ and nrdc_ lines that also contain "nr5g_band"
    line=$(printf '%s\n' "$raw" | grep '"nr5g_band"' | grep -v 'nsa_' | grep -v 'nrdc_' | head -1)
    if [ -n "$line" ]; then
        boot_supported_sa_nr5g_bands=$(printf '%s' "$line" | sed 's/.*"nr5g_band",//' | tr -d '\r ')
    fi

    line=$(printf '%s\n' "$raw" | grep '"nrdc_nr5g_band"' | head -1)
    if [ -n "$line" ]; then
        boot_supported_nrdc_nr5g_bands=$(printf '%s' "$line" | sed 's/.*"nrdc_nr5g_band",//' | tr -d '\r ')
    fi

    qlog_debug "policy_band: LTE=$boot_supported_lte_bands NSA=$boot_supported_nsa_nr5g_bands SA=$boot_supported_sa_nr5g_bands NRDC=$boot_supported_nrdc_nr5g_bands"
}

# =============================================================================
# IP Passthrough (IPPT) — boot-time parsers
# =============================================================================

# AT+QMAP="MPDN_RULE" → boot_ippt_mode ("disabled"|"eth"|"usb"), boot_ippt_mac
parse_ippt_mpdn_rule() {
    local raw="$1"
    local rule0
    local ippt_mode

    boot_ippt_mode="disabled"
    boot_ippt_mac=""

    # Anchor on the reply prefix; a set-form echo (AT+QMAP="MPDN_rule",0,...) also matches the key
    rule0=$(printf '%s\n' "$raw" | awk 'index($0,"+QMAP:")==1 && index($0,"\"MPDN_rule\",0,") {print; exit}')
    [ -z "$rule0" ] && return 0

    # Field 5 = IPPT_mode; +0 avoids BusyBox gsub $N rebuild bug
    ippt_mode=$(printf '%s' "$rule0" | awk -F',' '{print $5+0}')
    case "$ippt_mode" in
        1)
            boot_ippt_mode="eth"
            boot_ippt_mac=$(printf '%s' "$rule0" | awk -F',' 'NF>=7 {gsub(/"/, "", $7); print $7}')
            ;;
        3)
            boot_ippt_mode="usb"
            boot_ippt_mac=$(printf '%s' "$rule0" | awk -F',' 'NF>=7 {gsub(/"/, "", $7); print $7}')
            ;;
    esac

    qlog_debug "ippt_mpdn_rule: mode=$boot_ippt_mode mac=$boot_ippt_mac"
}

# AT+QMAP="IPPT_NAT" → boot_ippt_nat ("0"|"1")
parse_ippt_nat() {
    local raw="$1"
    local nat_val

    boot_ippt_nat="1"

    # Anchor on the +QMAP: reply line; a set-form echo (AT+QMAP="IPPT_NAT",N) also names the key
    nat_val=$(printf '%s\n' "$raw" | awk -F',' 'index($0,"+QMAP:")==1 && index($0,"\"IPPT_NAT\"") {print $2+0; exit}')
    case "$nat_val" in
        0|1) boot_ippt_nat="$nat_val" ;;
    esac

    qlog_debug "ippt_nat: $boot_ippt_nat"
}

# AT+QCFG="usbnet" → boot_ippt_usbnet ("0"|"1"|"2"|"3")
parse_ippt_usbnet() {
    local raw="$1"
    local usb_val

    boot_ippt_usbnet="1"

    # Anchor on the +QCFG: reply line; a set-form echo (AT+QCFG="usbnet",N) also names the key
    usb_val=$(printf '%s\n' "$raw" | awk -F',' 'index($0,"+QCFG:")==1 && index($0,"\"usbnet\"") {print $2+0; exit}')
    case "$usb_val" in
        0|1|2|3) boot_ippt_usbnet="$usb_val" ;;
    esac

    qlog_debug "ippt_usbnet: $boot_ippt_usbnet"
}

# AT+QMAP="DHCPV4DNS" → boot_ippt_dhcpv4dns ("enabled"|"disabled")
parse_ippt_dhcpv4dns() {
    local raw="$1"
    local dns_val

    boot_ippt_dhcpv4dns="disabled"

    # Anchor on the +QMAP: reply line; a set-form echo (AT+QMAP="DHCPV4DNS",...) also names the key
    dns_val=$(printf '%s\n' "$raw" | awk -F'"' 'index($0,"+QMAP:")==1 && index($0,"\"DHCPV4DNS\"") {print $4; exit}')
    case "$dns_val" in
        enable) boot_ippt_dhcpv4dns="enabled" ;;
    esac

    qlog_debug "ippt_dhcpv4dns: $boot_ippt_dhcpv4dns"
}
