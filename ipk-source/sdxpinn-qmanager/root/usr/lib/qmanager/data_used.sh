#!/bin/sh
# data_used.sh — persistent Data Used counter (ledger B5.21, U4.22).
#
# Sourced by qmanager_poller. Counts download (rx) and upload (tx) bytes across
# poller restarts, data-call / interface re-creation and reboots. Off the hot
# path by design (B5.29):
#   every cycle      one counter increment (no reset: the total runs from install)
#   every 15 cycles  builtin `read`s of qmi.env + /proc/uptime (and sysfs on
#                    fallback) + the RAM mirror (one mv)
#   every 10 samples the persistent file (qm_durable_write), also at init and
#                    on poller stop (du_flush from the poller's TERM trap)
# status.json is not touched; network/data_used.sh serves the RAM mirror.
#
# Sources, per sample (recorded as "source"):
#   wds     the modem's per-call QMI WDS byte counter (0x0024), published by the
#           broker in /var/run/qmanager/qmi.env. Preferred: IPA hardware offload
#           hides LAN-client traffic from every Linux netdev, and rmnet_ipa0
#           undercounts even modem-local traffic. Used only when the sidecar is
#           complete (qm_sidecar_end last), every line passes the qmi_merge.sh
#           charset rule, qmi_state=up, qmi_wds_ok=1, rx/tx are plain integers
#           and qmi_mono (CLOCK_BOOTTIME seconds of the last good read) is
#           0..DU_WDS_MAX_AGE s behind /proc/uptime. The file is parsed, never
#           sourced: it must not touch the qmi_* globals qmi_merge.sh owns.
#   netdev  fallback: rmnet_ipa0 statistics (aggregate WAN parent of
#           rmnet_data*; rx is download on SDX55/65/7X).
#
# Counter rules (docs/features/data-used.md), applied to the chosen source:
#   cur >= prev               add cur - prev
#   cur <  prev (either dir)  the counter restarted at 0 (netdev re-created, new
#                             WDS data call, SSR): add cur, iface_resets += 1
#   source switched           wds <-> netdev: prev = the new source's cur, add
#                             nothing (never a cross-source delta), not counted
#                             in iface_resets
#   boot_id changed           same as a restart, on the first sample of the boot
#   no state file             baseline only (bytes from before install are not ours)
#   no source readable        skip the sample, iface_present=false
#
# The poller is the ONLY writer of both files.

[ -n "$_QM_DATA_USED_LOADED" ] && return 0
_QM_DATA_USED_LOADED=1

# Overridable for tools/data-used-test/data-used-test.sh.
: "${DU_IFACE:=rmnet_ipa0}"
: "${DU_SYS_DIR:=/sys/class/net}"
: "${DU_BOOT_ID_FILE:=/proc/sys/kernel/random/boot_id}"
: "${DU_STATE_DIR:=/usrdata/qmanager}"
: "${DU_RUN_DIR:=/var/run/qmanager}"
: "${DU_SAMPLE_EVERY:=15}"
: "${DU_FLUSH_EVERY:=10}"
: "${DU_QMI_ENV:=/var/run/qmanager/qmi.env}"
: "${DU_UPTIME_FILE:=/proc/uptime}"
: "${DU_WDS_MAX_AGE:=30}"
DU_STATE_FILE="$DU_STATE_DIR/data_used.json"
DU_MIRROR="$DU_RUN_DIR/data_used.json"
DU_SCHEMA=1
# Below this the wall clock is the 1970 boot value: store 0, never a fake date.
DU_SANE_EPOCH=1700000000

_du_ready=0
_du_rx=0
_du_tx=0
_du_prev_rx=0
_du_prev_tx=0
_du_since=0
_du_updated=0
_du_resets=0
_du_present=false
_du_boot=""
_du_src="netdev"       # source of _du_prev_*: wds | netdev
_du_wr=""
_du_wx=""
_du_mode="baseline"    # baseline | rebase | delta
_du_n=0
_du_samples=0
_du_dirty=0

# _du_now: wall clock into _du_t (the poller's cycle _NOW when set), 0 if 1970.
_du_now() {
    _du_t="${_NOW:-}"
    case "$_du_t" in ''|*[!0-9]*) _du_t=$(date +%s 2>/dev/null) ;; esac
    case "$_du_t" in ''|*[!0-9]*) _du_t=0 ;; esac
    [ "$_du_t" -lt "$DU_SANE_EPOCH" ] && _du_t=0
}

_du_json() {
    printf '{"schema":%s,"rx_bytes":%s,"tx_bytes":%s,"since":%s,"updated":%s,"iface":"%s","source":"%s","iface_present":%s,"iface_resets":%s,"boot_id":"%s","prev_rx":%s,"prev_tx":%s}\n' \
        "$DU_SCHEMA" "$_du_rx" "$_du_tx" "$_du_since" "$_du_updated" \
        "$DU_IFACE" "$_du_src" "$_du_present" "$_du_resets" "$_du_boot" \
        "$_du_prev_rx" "$_du_prev_tx"
}

# RAM mirror: /var/run/qmanager is root 0700, so a fixed tmp name is safe.
_du_write_mirror() {
    _du_json > "$DU_MIRROR.tmp" 2>/dev/null && mv -f "$DU_MIRROR.tmp" "$DU_MIRROR" 2>/dev/null
}

# du_flush: persist to flash. Called every DU_FLUSH_EVERY samples when counts
# moved, at init and from the poller's TERM trap.
du_flush() {
    [ "$_du_ready" = "1" ] || return 0
    [ -d "$DU_STATE_DIR" ] || mkdir -p "$DU_STATE_DIR" 2>/dev/null
    if command -v qm_durable_write >/dev/null 2>&1; then
        _du_json | qm_durable_write "$DU_STATE_FILE" 0644
    else
        _du_json > "$DU_STATE_FILE.tmp" 2>/dev/null &&
            sync && mv -f "$DU_STATE_FILE.tmp" "$DU_STATE_FILE" && sync
    fi
    _du_dirty=0
    _du_samples=0
}

# _du_wds_read: set _du_wr / _du_wx from the broker's WDS counter when qmi.env
# is complete, fresh and says the read succeeded. Builtins only. Returns 1
# (fall back to the netdev) otherwise.
_du_wds_read() {
    local _l
    local _bad
    local _last
    local _m
    local _st
    local _ok
    local _up
    local _rest
    _du_wr=""
    _du_wx=""
    [ -f "$DU_QMI_ENV" ] || return 1
    _bad=0
    _last=""
    _m=""
    _st=""
    _ok=""
    {
        while IFS= read -r _l; do
            case "$_l" in
                *[!A-Za-z0-9_=\'-]*) _bad=1; break ;;
                qmi_mono=\'*\') _m="${_l#qmi_mono=\'}"; _m="${_m%\'}" ;;
                qmi_state=\'*\') _st="${_l#qmi_state=\'}"; _st="${_st%\'}" ;;
                qmi_wds_ok=\'*\') _ok="${_l#qmi_wds_ok=\'}"; _ok="${_ok%\'}" ;;
                qmi_wds_rx_bytes=\'*\') _du_wr="${_l#qmi_wds_rx_bytes=\'}"; _du_wr="${_du_wr%\'}" ;;
                qmi_wds_tx_bytes=\'*\') _du_wx="${_l#qmi_wds_tx_bytes=\'}"; _du_wx="${_du_wx%\'}" ;;
                qmi_*=\'*\'|qm_sidecar_end=\'1\') ;;
                *) _bad=1; break ;;
            esac
            _last="$_l"
        done < "$DU_QMI_ENV"
    } 2>/dev/null
    [ "$_bad" = "0" ] || return 1
    [ "$_last" = "qm_sidecar_end='1'" ] || return 1
    [ "$_st" = "up" ] || return 1
    [ "$_ok" = "1" ] || return 1
    # Digits only, no leading zero (ash reads 08 as bad octal); u64 values
    # above 19 digits would overflow ash's signed 64-bit arithmetic.
    case "$_du_wr" in ''|*[!0-9]*|0?*|????????????????????*) return 1 ;; esac
    case "$_du_wx" in ''|*[!0-9]*|0?*|????????????????????*) return 1 ;; esac
    case "$_m" in ''|*[!0-9]*|0?*|???????????*) return 1 ;; esac
    # Same clock as qmi_mono (CLOCK_BOOTTIME), read now rather than the
    # poller's cycle-start _MONO_TOP, so a sidecar written mid-cycle is not
    # "in the future".
    _up=""
    { read -r _up _rest < "$DU_UPTIME_FILE"; } 2>/dev/null
    _up="${_up%%.*}"
    case "$_up" in ''|*[!0-9]*|0?*|???????????*) return 1 ;; esac
    [ "$_up" -ge "$_m" ] || return 1
    [ $((_up - _m)) -le "$DU_WDS_MAX_AGE" ] || return 1
    return 0
}

# _du_sample: read the preferred source and fold it in. Returns 1 when no
# source could be read (state kept, iface_present=false).
_du_sample() {
    local _r
    local _x
    local _s
    _r=""
    _x=""
    if _du_wds_read; then
        _r="$_du_wr"
        _x="$_du_wx"
        _s="wds"
    else
        _s="netdev"
        { read -r _r < "$DU_SYS_DIR/$DU_IFACE/statistics/rx_bytes"; } 2>/dev/null
        { read -r _x < "$DU_SYS_DIR/$DU_IFACE/statistics/tx_bytes"; } 2>/dev/null
        case "$_r" in ''|*[!0-9]*) _du_present=false; return 1 ;; esac
        case "$_x" in ''|*[!0-9]*) _du_present=false; return 1 ;; esac
    fi
    _du_present=true
    _du_now
    _du_updated="$_du_t"

    case "$_du_mode" in
        baseline)
            _du_mode="delta"
            ;;
        rebase)
            _du_rx=$((_du_rx + _r))
            _du_tx=$((_du_tx + _x))
            _du_mode="delta"
            ;;
        *)
            if [ "$_s" != "$_du_src" ]; then
                # Two unrelated counters: re-baseline, never add across them.
                qlog_info "data_used: source $_du_src -> $_s; re-baselined (rx prev $_du_prev_rx -> $_r)"
            elif [ "$_r" -lt "$_du_prev_rx" ] || [ "$_x" -lt "$_du_prev_tx" ]; then
                _du_resets=$((_du_resets + 1))
                _du_rx=$((_du_rx + _r))
                _du_tx=$((_du_tx + _x))
                qlog_info "data_used: $_s counters restarted (rx $_du_prev_rx -> $_r); counting from 0"
            else
                _du_rx=$((_du_rx + _r - _du_prev_rx))
                _du_tx=$((_du_tx + _x - _du_prev_tx))
            fi
            ;;
    esac
    if [ "$_r" != "$_du_prev_rx" ] || [ "$_x" != "$_du_prev_tx" ] \
        || [ "$_s" != "$_du_src" ]; then
        _du_dirty=1
    fi
    _du_prev_rx="$_r"
    _du_prev_tx="$_x"
    _du_src="$_s"
    return 0
}

# _du_load: read the persisted state. Returns 1 (caller starts fresh) when the
# file is absent, another schema, or any field fails its guard.
_du_load() {
    local _line
    [ -f "$DU_STATE_FILE" ] || return 1
    _line=$(jq -r '[(.schema // 0), (.rx_bytes // 0), (.tx_bytes // 0),
                    (.since // 0), (.iface_resets // 0), (.prev_rx // 0),
                    (.prev_tx // 0),
                    (if (.boot_id // "") == "" then "-" else .boot_id end),
                    (if .source == "wds" then "wds" else "netdev" end)]
                   | map(tostring) | join(" ")' "$DU_STATE_FILE" 2>/dev/null)
    [ -n "$_line" ] || return 1
    local _noglob
    _noglob=0
    case $- in *f*) _noglob=1 ;; esac
    set -f
    # shellcheck disable=SC2086
    set -- $_line
    [ "$_noglob" -eq 0 ] && set +f
    [ "$#" -eq 9 ] || return 1
    [ "$1" = "$DU_SCHEMA" ] || return 1
    local _v
    for _v in "$2" "$3" "$4" "$5" "$6" "$7"; do
        case "$_v" in ''|*[!0-9]*) return 1 ;; esac
    done
    _du_rx="$2"
    _du_tx="$3"
    _du_since="$4"
    _du_resets="$5"
    _du_prev_rx="$6"
    _du_prev_tx="$7"
    _du_file_boot="$8"
    # Files from before the WDS source have no "source": their prev is netdev.
    _du_src="$9"
    return 0
}

# du_init: once at poller start, after safe_tmp.sh is loaded.
du_init() {
    if command -v qm_run_dir >/dev/null 2>&1; then
        qm_run_dir >/dev/null 2>&1
    else
        mkdir -p "$DU_RUN_DIR" 2>/dev/null
    fi
    _du_boot=""
    { read -r _du_boot < "$DU_BOOT_ID_FILE"; } 2>/dev/null
    case "$_du_boot" in ''|*[!0-9a-f-]*) _du_boot="" ;; esac

    _du_file_boot=""
    if _du_load; then
        if [ -n "$_du_boot" ] && [ "$_du_file_boot" = "$_du_boot" ]; then
            _du_mode="delta"
        else
            # New boot (or unknown boot): every byte on the source is new.
            _du_mode="rebase"
        fi
    else
        [ -f "$DU_STATE_FILE" ] && qlog_warn "data_used: state file unreadable, starting from zero"
        _du_rx=0
        _du_tx=0
        _du_resets=0
        _du_prev_rx=0
        _du_prev_tx=0
        _du_now
        _du_since="$_du_t"
        _du_mode="baseline"
    fi
    _du_ready=1
    _du_sample
    _du_write_mirror
    du_flush
    qlog_info "data_used: started (source=$_du_src mode=$_du_mode rx=$_du_rx tx=$_du_tx)"
}

# du_tick: every poller cycle.
du_tick() {
    [ "$_du_ready" = "1" ] || return 0
    _du_n=$((_du_n + 1))
    [ "$_du_n" -ge "$DU_SAMPLE_EVERY" ] || return 0
    _du_n=0
    _du_sample
    _du_write_mirror
    _du_samples=$((_du_samples + 1))
    if [ "$_du_dirty" = "1" ] && [ "$_du_samples" -ge "$DU_FLUSH_EVERY" ]; then
        du_flush
    fi
}
