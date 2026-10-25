# shellcheck shell=sh
# =============================================================================
# qmi_merge.sh — QMI gap-fill for the poller (QMI Phase 2, step 1)
# =============================================================================
# Sourced by qmanager_poller (guarded `[ -f ] && .`; missing lib = AT only).
#
# The broker's sampler publishes /var/run/qmanager/qmi.env every 2 s (contract:
# docs/features/qmi-lane.md). On cycles where AT did not read the serving cell
# (idle/deep tiers between AT touches, a busy QENG), the LTE serving signal in
# status.json is filled from it, under identity, registration and freshness
# gates. The fill is an overlay: qmi_overlay_apply runs right before the final
# write_cache and qmi_overlay_restore right after it, so every AT consumer
# (events.sh, signal history, busy logic, the parity dumps) only ever sees AT
# samples. The scan / SIM-switch early-return write_cache never overlays.
#
# Hot path: builtins only, zero forks (the stamp is written with a redirect).
# =============================================================================

QMI_ENV="${QMI_ENV:-/var/run/qmanager/qmi.env}"
QMI_STAMP="${QMI_STAMP:-/var/run/qmanager/qmi.stamp}"
QMI_FORCE_EVERY="${QMI_FORCE_EVERY:-15}"
QMI_MAX_AGE="${QMI_MAX_AGE:-5}"
QMI_SCAN_FLAG="${QMI_SCAN_FLAG:-/tmp/qmanager_long_running}"
QMI_SIMSW_FLAG="${QMI_SIMSW_FLAG:-/tmp/qmanager_sim_switch_active}"

_qmi_calls=0
# 1 while the last load found a complete, valid sidecar.
_QMI_OK=0
# Published as device.qmi_read_mono / qmi_state / qmi_ssr_count (sanitised).
_QMI_READ_MONO=0
_QMI_STATE=""
_QMI_SSR=0
# Published as lte.source.
lte_source="at"
# Overlay save slots.
_QMO_ACTIVE=0
_qmo_rsrp=""
_qmo_rsrq=""
_qmo_rssi=""

# _qmi_env_source: source QMI_ENV only if every line is a single-quoted qmi_*
# assignment whose value has no shell-active character, and the last line is
# the end marker. Stricter than cq_env_source: a sourced line can only ever
# assign a qmi_* variable, never a poller global. Returns 1 without sourcing.
# Evaluates the lines it validated rather than re-opening the file: a broker
# stop deletes qmi.env, and `.` on a missing file aborts the poller.
_qmi_env_source() {
    _qes_last=""
    _qes_buf=""
    _qes_bad=0
    {
        while IFS= read -r _qes_l; do
            case "$_qes_l" in
                *[!A-Za-z0-9_=\'-]*) _qes_bad=1; break ;;
                qmi_*=\'*\'|qm_sidecar_end=\'1\') ;;
                *) _qes_bad=1; break ;;
            esac
            _qes_last="$_qes_l"
            _qes_buf="$_qes_buf$_qes_l
"
        done < "$QMI_ENV"
    } 2>/dev/null
    [ "$_qes_bad" = "0" ] || return 1
    [ "$_qes_last" = "qm_sidecar_end='1'" ] || return 1
    eval "$_qes_buf"
}

# _qmi_int <value>: true when the value is a plain integer (optional minus,
# no leading zero).
_qmi_int() {
    case "$1" in
        ''|-|*[!0-9-]*|?*-*|0?*|-0*) return 1 ;;
    esac
    return 0
}

# qmi_load: refresh the qmi_* globals from the sidecar. The sidecar is re-read
# when it is not older than the stamp (same second counts as newer, which is
# what backdating the stamp by one second gives), plus a forced re-read every
# QMI_FORCE_EVERY calls. The stamp is written before the read with a builtin
# redirect. Returns 0 when a valid sidecar is loaded.
qmi_load() {
    if [ ! -f "$QMI_ENV" ]; then
        _QMI_OK=0
        _QMI_READ_MONO=0
        _QMI_STATE=""
        _QMI_SSR=0
        return 1
    fi
    _qmi_calls=$((_qmi_calls + 1))
    if [ "$_QMI_OK" = "1" ] && [ "$_qmi_calls" -lt "$QMI_FORCE_EVERY" ] \
        && [ "$QMI_STAMP" -nt "$QMI_ENV" ]; then
        return 0
    fi
    _qmi_calls=0
    # `true`, not `:`: a redirect error on a special builtin exits the shell.
    true 2>/dev/null > "$QMI_STAMP"
    qmi_mono=""
    qmi_state=""
    qmi_ssr_count=""
    qmi_registered=""
    qmi_lte_pci=""
    qmi_lte_earfcn=""
    qmi_lte_rsrp=""
    qmi_lte_rsrq=""
    qmi_lte_rssi=""
    if ! _qmi_env_source; then
        _QMI_OK=0
        _QMI_READ_MONO=0
        _QMI_STATE=""
        _QMI_SSR=0
        return 1
    fi
    _QMI_OK=1
    # Digits only, no leading zero (ash reads 08 as bad octal), <= 10 digits.
    case "$qmi_mono" in
        ''|*[!0-9]*|0?*|???????????*) _QMI_READ_MONO=0 ;;
        *) _QMI_READ_MONO="$qmi_mono" ;;
    esac
    case "$qmi_state" in
        up|down|unavailable) _QMI_STATE="$qmi_state" ;;
        *) _QMI_STATE="" ;;
    esac
    case "$qmi_ssr_count" in
        ''|*[!0-9]*|0?*|???????????*) _QMI_SSR=0 ;;
        *) _QMI_SSR="$qmi_ssr_count" ;;
    esac
    return 0
}

# qmi_overlay_apply: fill lte_rsrp / lte_rsrq / lte_rssi from QMI for the next
# write_cache when every gate holds; sets lte_source to qmi or at.
#   - AT did not parse a serving-cell reply this cycle (_QENG_PARSED != 1);
#   - no scan or SIM switch is flagged, and system_state is not still
#     scan_in_progress from one (D2);
#   - a valid sidecar, qmi_state=up, registered;
#   - read age (uptime clock) 0..QMI_MAX_AGE s;
#   - QMI LTE PCI and EARFCN equal the AT ones, or AT knows no serving cell
#     (no LTE and no NR PCI), so a handover between AT reads is never merged;
#   - all three QMI values are integers.
qmi_overlay_apply() {
    lte_source="at"
    _QMO_ACTIVE=0
    [ "${_QENG_PARSED:-0}" = "1" ] && return 1
    [ "$_QMI_OK" = "1" ] || return 1
    [ "$_QMI_STATE" = "up" ] || return 1
    [ "$qmi_registered" = "1" ] || return 1
    [ -f "$QMI_SCAN_FLAG" ] && return 1
    [ -f "$QMI_SIMSW_FLAG" ] && return 1
    # After a scan the deep/idle tier keeps reporting scan_in_progress until its
    # next AT read; stay AT-only until then so the snapshot stays coherent.
    [ "$system_state" = "scan_in_progress" ] && return 1
    case "${_MONO_TOP:-0}" in ''|0|*[!0-9]*) return 1 ;; esac
    [ "$_QMI_READ_MONO" -gt 0 ] || return 1
    [ "$_MONO_TOP" -ge "$_QMI_READ_MONO" ] || return 1
    [ $((_MONO_TOP - _QMI_READ_MONO)) -le "$QMI_MAX_AGE" ] || return 1
    _qmi_int "$qmi_lte_pci" || return 1
    _qmi_int "$qmi_lte_earfcn" || return 1
    if [ -n "$lte_pci" ] || [ -n "$lte_earfcn" ]; then
        [ "$qmi_lte_pci" = "$lte_pci" ] || return 1
        [ "$qmi_lte_earfcn" = "$lte_earfcn" ] || return 1
    elif [ -n "$nr_pci" ]; then
        return 1
    fi
    _qmi_int "$qmi_lte_rsrp" || return 1
    _qmi_int "$qmi_lte_rsrq" || return 1
    _qmi_int "$qmi_lte_rssi" || return 1
    _qmo_rsrp="$lte_rsrp"
    _qmo_rsrq="$lte_rsrq"
    _qmo_rssi="$lte_rssi"
    _QMO_ACTIVE=1
    lte_rsrp="$qmi_lte_rsrp"
    lte_rsrq="$qmi_lte_rsrq"
    lte_rssi="$qmi_lte_rssi"
    lte_source="qmi"
    return 0
}

# qmi_overlay_restore: put the AT values back after write_cache.
qmi_overlay_restore() {
    if [ "$_QMO_ACTIVE" = "1" ]; then
        lte_rsrp="$_qmo_rsrp"
        lte_rsrq="$_qmo_rsrq"
        lte_rssi="$_qmo_rssi"
        _QMO_ACTIVE=0
    fi
    lte_source="at"
}
