#!/bin/sh
# safe_tmp.sh — root-safe handling of predictable paths in /tmp (ledger B4.1).
#
# /tmp is world-writable + sticky. On the RM551E fs.protected_symlinks=1 stops
# root following a symlink another user planted directly in /tmp, but
# protected_regular=0 and protected_fifos=0: a file or FIFO planted at a fixed
# name is opened by root's `>` and stays owned (and rewritable) by the planter.
# Nothing protects the entries of a directory another user created first, so
# `mkdir -p /tmp/x` followed by a write inside it is fully attacker-steerable.
#
# Rules this lib serves:
#   - Anything root sources, executes, extracts and installs, or kills by pid
#     must be a root-owned regular file (qm_trusted_file / qm_read_pid).
#   - A directory root writes into is a real root-owned dir (qm_root_dir), or
#     lives under /var/run (root 0755, not world-writable).
#   - A file root rewrites in /tmp goes mktemp + rename (qm_atomic_write):
#     rename replaces a planted file, FIFO or symlink instead of writing
#     through it, and leaves a root-owned file behind.
#
# Locks are NOT moved by this lib: a flock target only needs to exist, and the
# FD numbers and paths other scripts share stay as they are.

[ -n "$_QM_SAFE_TMP_LOADED" ] && return 0
_QM_SAFE_TMP_LOADED=1

# Root-only scratch for QManager (/var/run is /tmp/run here: root 0755).
QM_RUN_DIR="/var/run/qmanager"

# qm_owned_by_root PATH — PATH exists, is not a symlink, and its owner is uid 0.
qm_owned_by_root() {
    [ -L "$1" ] && return 1
    [ -e "$1" ] || return 1
    [ "$(stat -c %u "$1" 2>/dev/null)" = "0" ]
}

# qm_trusted_file PATH — a regular, root-owned, non-symlink file.
# Gate every `.`, exec, extract or pid read of a /tmp path on this.
qm_trusted_file() {
    [ -f "$1" ] && qm_owned_by_root "$1"
}

# qm_root_dir DIR [MODE] — make DIR a real root-owned directory with MODE
# (default 0700). A symlink, file, FIFO or another user's directory at DIR is
# removed first (rm on a symlink unlinks the link, never its target). Returns 1
# if DIR cannot be made trustworthy; the caller must then not use it.
qm_root_dir() {
    _qrd_dir="$1"
    _qrd_mode="${2:-0700}"
    if [ -d "$_qrd_dir" ] && qm_owned_by_root "$_qrd_dir"; then
        chmod "$_qrd_mode" "$_qrd_dir" 2>/dev/null
        return 0
    fi
    rm -rf "$_qrd_dir" 2>/dev/null
    mkdir -m "$_qrd_mode" "$_qrd_dir" 2>/dev/null || return 1
    qm_owned_by_root "$_qrd_dir"
}

# qm_run_dir — ensure QM_RUN_DIR exists (root 0700) and print it.
qm_run_dir() {
    qm_root_dir "$QM_RUN_DIR" 0700 || return 1
    printf '%s' "$QM_RUN_DIR"
}

# _qm_replace DEST MODE FLUSH — shared body of qm_atomic_write and
# qm_durable_write. FLUSH=1 syncs before the rename (so the data is on flash
# before the name points at it) and after it (so the rename itself is).
_qm_replace() {
    _qaw_dest="$1"
    _qaw_mode="$2"
    _qaw_flush="$3"
    # mv onto a directory would move the temp INTO it; clear a planted dir.
    if [ -d "$_qaw_dest" ] && [ ! -L "$_qaw_dest" ]; then
        rm -rf "$_qaw_dest" 2>/dev/null
    fi
    _qaw_tmp=$(mktemp "${_qaw_dest}.XXXXXX" 2>/dev/null) || {
        cat > /dev/null
        return 1
    }
    if cat > "$_qaw_tmp" && chmod "$_qaw_mode" "$_qaw_tmp"; then
        [ "$_qaw_flush" = "1" ] && sync
        if mv -f "$_qaw_tmp" "$_qaw_dest"; then
            [ "$_qaw_flush" = "1" ] && sync
            return 0
        fi
    fi
    rm -f "$_qaw_tmp" 2>/dev/null
    return 1
}

# qm_atomic_write DEST [MODE] — write stdin to DEST via a mktemp sibling and a
# rename (default mode 0644). Returns 1 (DEST untouched) on any failure.
# For RAM paths (/tmp, /var/run). Persistent files use qm_durable_write.
qm_atomic_write() {
    _qm_replace "$1" "${2:-0644}" 0
}

# qm_durable_write DEST [MODE] — qm_atomic_write for files on flash (/etc,
# /usr, /www: UBIFS, 30 s writeback). Without the syncs a power cut or AP hang
# can commit the rename before the data and leave DEST 0 bytes. BusyBox sync
# is a global flush, so keep this off poll loops. stdin must be the full
# content: build it into a variable first when a failed producer (jq) could
# pipe nothing, or an empty DEST is written durably.
qm_durable_write() {
    _qm_replace "$1" "${2:-0644}" 1
}

# qm_self_pid — set QM_SELF_PID to the pid of the calling shell process. Unlike
# $$ this is right inside a ( ... ) subshell (ash keeps $$ as the parent's pid):
# `read` is a builtin, so /proc/self is the subshell itself. Call it directly,
# never as $(qm_self_pid): command substitution forks and would report the fork.
qm_self_pid() {
    QM_SELF_PID=""
    read -r QM_SELF_PID _qsp_rest < /proc/self/stat 2>/dev/null
    case "$QM_SELF_PID" in
        ''|*[!0-9]*) QM_SELF_PID=""; return 1 ;;
    esac
    return 0
}

# qm_read_pid PIDFILE [CMDLINE_SUBSTR] — print the pid in PIDFILE when the file
# is root-owned, the pid is numeric (> 1) and alive, and, if given, its
# /proc cmdline contains CMDLINE_SUBSTR. Returns 1 otherwise. Use it before
# any `kill` of a pid read from /tmp.
qm_read_pid() {
    qm_trusted_file "$1" || return 1
    _qrp_pid=$(head -n 1 "$1" 2>/dev/null | tr -d ' \t\r')
    case "$_qrp_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$_qrp_pid" -gt 1 ] 2>/dev/null || return 1
    [ -d "/proc/$_qrp_pid" ] || return 1
    if [ -n "$2" ]; then
        tr '\0' ' ' < "/proc/$_qrp_pid/cmdline" 2>/dev/null | grep -qF -- "$2" || return 1
    fi
    printf '%s' "$_qrp_pid"
}
