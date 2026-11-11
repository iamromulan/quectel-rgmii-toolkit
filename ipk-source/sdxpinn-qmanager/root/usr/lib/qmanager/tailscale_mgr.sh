#!/bin/sh
# =============================================================================
# tailscale_mgr.sh — Tailscale install / update pipeline (two sources)
# =============================================================================
# Official: static arm64 builds from pkgs.tailscale.com/stable (GitHub
# releases carry no binaries). Every build is staged in RAM, sha256-verified
# (fail closed) and smoke-tested before anything under /usr/bin is touched.
# Updates swap binaries in place (.new + rename), restart through
# /etc/init.d/tailscale (its stop_service is a no-op, so tailscaled.state,
# WantRunning and the command line are preserved and the node stays logged
# in), then health-check and roll back to the kept old binaries on failure.
#
# Tiny: iamromulan's tailscale-tiny opkg package, offered only when the
# firmware already trusts his signed feed (ts_tiny_available). opkg verifies
# the feed signature and the ipk checksum. The package is installed as-is:
# its own init script, config and network setup, none of QManager's
# (no qm_write_ts_initd, no UCI seed, no tailscale_net.sh). Updates go through
# opkg with a RAM copy of the old binary for rollback, and put the user's
# boot-enable choice back afterwards (the package postinst always enables).
#
# Entry points run inside a background worker (the CGI orphans it):
#   ts_do_install <official|tiny>   ts_do_update
# Test knobs (shell only, the CGI unsets them): TS_TEST_FAIL_HEALTH=1 forces
# ts_wait_healthy to fail so the rollback path can be exercised;
# TS_TEST_FORCE_UPDATE=1 makes a Tiny update reinstall the current version.
#
# Never changes tailscaled's parameters; tailscale_initd.sh is the only init
# writer, and only for the official source.
# =============================================================================

[ -n "$_TS_MGR_LOADED" ] && return 0
_TS_MGR_LOADED=1

[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh
[ -f /usr/lib/qmanager/tailscale_initd.sh ] && . /usr/lib/qmanager/tailscale_initd.sh
[ -f /usr/lib/qmanager/tailscale_net.sh ] && . /usr/lib/qmanager/tailscale_net.sh

TS_BIN_DIR="/usr/bin"
TS_INSTALL_MARKER="/etc/tailscale/.qm_install_method"
TS_PROGRESS_FILE="/tmp/qmanager_tailscale_install.json"
TS_LOCK_FILE="/var/lock/qmanager_tailscale_migrate.lock"
TS_LATEST_CACHE="/var/run/qmanager/tailscale_latest.json"
TS_PKGS_BASE="https://pkgs.tailscale.com/stable"
TS_LATEST_TTL=21600
TS_LATEST_FAIL_TTL=1800
TS_OP="${TS_OP:-install}"
# official | tiny. Selects the latest-version fetcher and cache; workers set it.
TS_SOURCE="${TS_SOURCE:-official}"

TS_TINY_PKG="tailscale-tiny"
TS_TINY_ARCH="aarch64_cortex-a53"
TS_TINY_BIN_DIR="/usr/sbin"
TS_TINY_CACHE="/var/run/qmanager/tailscale_tiny_latest.json"
TS_OPKG_STATUS="/usr/lib/opkg/status"
# Both the feed name and its usign key comment start with this.
TS_TINY_FEED_TAG="iamromulan"

# --- small helpers -----------------------------------------------------------

# _ts_num VALUE — print VALUE if it is a non-negative integer, else 0.
_ts_num() {
    case "$1" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$1" ;;
    esac
}

# _ts_size_kb FILE — real size in KB (rounded up) from ls -l, 0 if unknown.
_ts_size_kb() {
    local b
    b=$(ls -l "$1" 2>/dev/null | awk '{print $5}')
    b=$(_ts_num "$b")
    printf '%s' $(( (b + 1023) / 1024 ))
}

# _ts_df_free_kb PATH — free KB on the filesystem holding PATH, 0 if unknown.
_ts_df_free_kb() {
    local v
    v=$(df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4}')
    _ts_num "$v"
}

_ts_mem_avail_kb() {
    local v
    v=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    _ts_num "$v"
}

_ts_now() {
    _ts_num "$(date +%s 2>/dev/null)"
}

_ts_bin_path() {
    command -v "$1" 2>/dev/null
}

# --- progress ----------------------------------------------------------------

# ts_progress <status> <message> [detail] [error_code]
# Writes the progress file atomically and echoes the line to stdout, which in
# the worker is the live install log.
ts_progress() {
    local ok
    local json
    ok=true
    [ "$1" = "error" ] && ok=false
    json=$(jq -cn \
        --argjson ok "$ok" \
        --arg status "$1" \
        --arg message "$2" \
        --arg detail "${3:-}" \
        --arg error "${4:-}" \
        --arg op "$TS_OP" \
        --arg source "$TS_SOURCE" \
        '{success: $ok, status: $status, message: $message, op: $op}
         + (if $detail != "" then {detail: $detail} else {} end)
         + (if $error != "" then {error: $error} else {} end)
         + (if $status == "complete" then {variant: $source} else {} end)' 2>/dev/null)
    if [ -n "$json" ]; then
        if command -v qm_atomic_write >/dev/null 2>&1; then
            printf '%s' "$json" | qm_atomic_write "$TS_PROGRESS_FILE"
        else
            printf '%s' "$json" > "$TS_PROGRESS_FILE"
        fi
    fi
    if [ -n "$3" ]; then
        printf '%s: %s\n' "$2" "$3"
    else
        printf '%s\n' "$2"
    fi
}

# _ts_fail <error_code> <message> [detail] — progress error, return 1.
_ts_fail() {
    ts_progress error "$2" "${3:-}" "$1"
    return 1
}

# Generic failure code for the current op (install_failed / update_failed).
_ts_generic_code() {
    printf '%s_failed' "$TS_OP"
}

# --- lock --------------------------------------------------------------------
# /var/lock/qmanager_tailscale_migrate.lock holds "<pid>\n<op>". A pid that is
# not alive (or a file that is not root-owned) is stale. The CGI pre-acquires
# the lock with its own pid before spawning the worker; the worker then takes
# it over (ash keeps $$ as the CGI's pid inside the subshell), so there is no
# window in which a second request could start a second worker.

# ts_lock_holder — print the live holder pid, rc 1 when free or stale.
ts_lock_holder() {
    qm_read_pid "$TS_LOCK_FILE"
}

# ts_lock_op — print the op recorded by a live holder ("" for install.sh).
ts_lock_op() {
    ts_lock_holder >/dev/null || return 1
    sed -n '2p' "$TS_LOCK_FILE" 2>/dev/null | tr -d ' \r\n'
}

ts_lock_acquire() {
    local op
    local holder
    local tries
    op="${1:-$TS_OP}"
    qm_self_pid || return 1
    TS_LOCK_PID="$QM_SELF_PID"
    tries=0
    while [ "$tries" -lt 2 ]; do
        if ( set -C; printf '%s\n%s\n' "$TS_LOCK_PID" "$op" > "$TS_LOCK_FILE" ) 2>/dev/null; then
            return 0
        fi
        if holder=$(ts_lock_holder); then
            if [ "$holder" = "$TS_LOCK_PID" ] || [ "$holder" = "$$" ]; then
                printf '%s\n%s\n' "$TS_LOCK_PID" "$op" | qm_atomic_write "$TS_LOCK_FILE" 0644
                return $?
            fi
            return 1
        fi
        rm -f "$TS_LOCK_FILE"
        tries=$((tries + 1))
    done
    return 1
}

ts_lock_release() {
    local holder
    [ -n "$TS_LOCK_PID" ] || return 0
    holder=$(head -n 1 "$TS_LOCK_FILE" 2>/dev/null | tr -d ' \r')
    [ "$holder" = "$TS_LOCK_PID" ] && rm -f "$TS_LOCK_FILE"
    TS_LOCK_PID=""
    return 0
}

# --- detection ---------------------------------------------------------------

# official / tiny / opkg / none. The marker is authoritative; opkg detection
# covers installs that predate it.
ts_variant() {
    local marker
    if ! command -v tailscale >/dev/null 2>&1 || ! command -v tailscaled >/dev/null 2>&1; then
        echo "none"
        return 0
    fi
    if [ -f "$TS_INSTALL_MARKER" ]; then
        marker=$(tr -d ' \n\r' < "$TS_INSTALL_MARKER" 2>/dev/null)
        case "$marker" in
            official|tiny) echo "$marker"; return 0 ;;
        esac
    fi
    if [ -f "/usr/lib/opkg/info/$TS_TINY_PKG.control" ]; then
        echo "tiny"
        return 0
    fi
    echo "opkg"
}

ts_installed_version() {
    tailscale version 2>/dev/null | head -n 1 | awk '{print $1}'
}

# _ts_pkgver_norm RAW — opkg version to dotted numeric ("1.104.2-r1" ->
# "1.104.2.1", "1.104.2" unchanged), "" when not numeric.
_ts_pkgver_norm() {
    local v
    local rel
    v="$1"
    case "$v" in *:*) v="${v#*:}" ;; esac
    case "$v" in
        *-*)
            rel="${v#*-}"
            rel="${rel#r}"
            v="${v%%-*}.$rel"
            ;;
    esac
    case "$v" in ''|*[!0-9.]*) return 0 ;; esac
    printf '%s' "$v"
}

# ts_tiny_pkg_version — installed tailscale-tiny package version, normalized.
ts_tiny_pkg_version() {
    local raw
    raw=$(awk -v p="$TS_TINY_PKG" '
        /^Package: / { inpkg = ($2 == p) }
        inpkg && /^Version: / { print $2; exit }
    ' "$TS_OPKG_STATUS" 2>/dev/null | tr -d '\r')
    _ts_pkgver_norm "$raw"
}

# ts_compare_version — the version update checks compare against: the package
# version on Tiny (catches -rN rebuilds), the binary version otherwise.
ts_compare_version() {
    if [ "$(ts_variant)" = "tiny" ]; then
        ts_tiny_pkg_version
    else
        ts_installed_version
    fi
}

# ts_tiny_feed_url — https URL of the iamromulan feed from the device's own
# opkg config. Nothing is ever added; no feed line means no Tiny source.
ts_tiny_feed_url() {
    awk -v tag="$TS_TINY_FEED_TAG" '
        $1 == "src/gz" && index($2, tag) == 1 && $3 ~ /^https:\/\// { print $3; exit }
    ' /etc/opkg/customfeeds.conf /etc/opkg/distfeeds.conf 2>/dev/null | tr -d '\r'
}

# ts_tiny_available — rc 0 when the firmware already trusts the Tiny feed:
# feed line, its usign key, signature checking on, and the package's arch.
ts_tiny_available() {
    local k
    local keyed
    command -v opkg >/dev/null 2>&1 || return 1
    [ -n "$(ts_tiny_feed_url)" ] || return 1
    grep -q '^option check_signature' /etc/opkg.conf 2>/dev/null || return 1
    cat /etc/opkg/arch.conf /etc/opkg.conf 2>/dev/null \
        | awk -v a="$TS_TINY_ARCH" '$1 == "arch" && $2 == a { f = 1 } END { exit !f }' || return 1
    keyed=1
    for k in /etc/opkg/keys/*; do
        [ -f "$k" ] || continue
        if head -n 1 "$k" 2>/dev/null | grep -q "untrusted comment: $TS_TINY_FEED_TAG"; then
            keyed=0
            break
        fi
    done
    return "$keyed"
}

# ts_version_gt A B — rc 0 when dotted-numeric A > B. Non-numeric input is never greater.
ts_version_gt() {
    case "$1" in ''|*[!0-9.]*) return 1 ;; esac
    case "$2" in ''|*[!0-9.]*) return 1 ;; esac
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".")
        n = (na > nb) ? na : nb
        for (i = 1; i <= n; i++) {
            p = (i <= na) ? x[i] + 0 : 0
            q = (i <= nb) ? y[i] + 0 : 0
            if (p > q) exit 0
            if (p < q) exit 1
        }
        exit 1
    }'
}

# --- latest version ----------------------------------------------------------

# The latest-version cache of the current TS_SOURCE.
_ts_cache_file() {
    if [ "$TS_SOURCE" = "tiny" ]; then
        printf '%s' "$TS_TINY_CACHE"
    else
        printf '%s' "$TS_LATEST_CACHE"
    fi
}

# _ts_tiny_fetch_latest — print "<version>\t<ipk>" from the feed's Packages
# index. Display / comparison only: the install itself goes through opkg,
# which verifies the signed index.
_ts_tiny_fetch_latest() {
    local url
    local idx
    local raw
    local ipk
    local ver
    url=$(ts_tiny_feed_url)
    [ -n "$url" ] || return 1
    idx=$(curl -fsSL --proto =https --proto-redir =https --retry "${TS_FETCH_RETRY:-2}" --max-time 20 \
        --max-filesize 1048576 "$url/Packages" 2>/dev/null) || return 1
    raw=$(printf '%s\n' "$idx" | tr -d '\r' | awk -v p="$TS_TINY_PKG" '
        /^Package: / { inpkg = ($2 == p) }
        inpkg && /^Version: / { v = $2 }
        inpkg && /^Filename: / { f = $2 }
        END { if (v != "" && f != "") print v "\t" f }
    ')
    ver=$(_ts_pkgver_norm "$(printf '%s' "$raw" | cut -f1)")
    ipk=$(printf '%s' "$raw" | cut -f2)
    [ -n "$ver" ] || return 1
    case "$ipk" in
        "$TS_TINY_PKG"_*.ipk) : ;;
        *) return 1 ;;
    esac
    case "$ipk" in */*) return 1 ;; esac
    printf '%s\t%s\n' "$ver" "$ipk"
}

# ts_fetch_latest — print "<version>\t<artifact>" for the current source.
ts_fetch_latest() {
    local meta
    local ver
    local tarball
    if [ "$TS_SOURCE" = "tiny" ]; then
        _ts_tiny_fetch_latest
        return $?
    fi
    meta=$(curl -fsSL --proto =https --proto-redir =https --retry "${TS_FETCH_RETRY:-2}" --max-time 20 "$TS_PKGS_BASE/?mode=json" 2>/dev/null) || return 1
    ver=$(printf '%s' "$meta" | jq -r '(.TarballsVersion // .Version) | if . == null then empty else tostring end' 2>/dev/null)
    case "$ver" in ''|*[!0-9.]*) return 1 ;; esac
    tarball=$(printf '%s' "$meta" | jq -r '.Tarballs.arm64 | if . == null then empty else tostring end' 2>/dev/null)
    [ "$tarball" = "tailscale_${ver}_arm64.tgz" ] || return 1
    printf '%s\t%s\n' "$ver" "$tarball"
}

# ts_latest_refresh — fetch and write the cache. Sets TS_LATEST_VER and
# TS_LATEST_TARBALL on success. A failure keeps the last good version in the
# cache but stamps the attempt, so callers back off for TS_LATEST_FAIL_TTL.
ts_latest_refresh() {
    local line
    local now
    local prev_ver
    local prev_tar
    local prev_ok_at
    local json
    local cache
    now=$(_ts_now)
    cache=$(_ts_cache_file)
    TS_LATEST_VER=""
    TS_LATEST_TARBALL=""
    qm_run_dir >/dev/null 2>&1
    if line=$(ts_fetch_latest); then
        TS_LATEST_VER=$(printf '%s' "$line" | cut -f1)
        TS_LATEST_TARBALL=$(printf '%s' "$line" | cut -f2)
        json=$(jq -cn --arg v "$TS_LATEST_VER" --arg t "$TS_LATEST_TARBALL" --argjson now "$now" \
            '{version: $v, tarball: $t, checked_at: $now, ok_at: $now, ok: true}')
        [ -n "$json" ] && printf '%s' "$json" | qm_atomic_write "$cache"
        return 0
    fi
    prev_ver=""
    prev_tar=""
    prev_ok_at=0
    if qm_trusted_file "$cache"; then
        prev_ver=$(jq -r '.version // ""' "$cache" 2>/dev/null)
        prev_tar=$(jq -r '.tarball // ""' "$cache" 2>/dev/null)
        prev_ok_at=$(_ts_num "$(jq -r '.ok_at // 0' "$cache" 2>/dev/null)")
    fi
    json=$(jq -cn --arg v "$prev_ver" --arg t "$prev_tar" --argjson now "$now" --argjson okat "$prev_ok_at" \
        '{version: $v, tarball: $t, checked_at: $now, ok_at: $okat, ok: false}')
    [ -n "$json" ] && printf '%s' "$json" | qm_atomic_write "$cache"
    return 1
}

# _ts_cache_field NAME — print a cache field ("" when absent/untrusted).
_ts_cache_field() {
    local cache
    cache=$(_ts_cache_file)
    qm_trusted_file "$cache" || return 1
    jq -r --arg k "$1" '.[$k] | if . == null then empty else tostring end' "$cache" 2>/dev/null
}

# ts_latest_cache_read — print the cached version if the last good check is
# younger than TS_LATEST_TTL. Never touches the network.
ts_latest_cache_read() {
    local v
    local ok_at
    local age
    v=$(_ts_cache_field version) || return 0
    case "$v" in ''|*[!0-9.]*) return 0 ;; esac
    ok_at=$(_ts_num "$(_ts_cache_field ok_at)")
    [ "$ok_at" -gt 0 ] || return 0
    age=$(( $(_ts_now) - ok_at ))
    if [ "$age" -ge 0 ] && [ "$age" -lt "$TS_LATEST_TTL" ]; then
        printf '%s' "$v"
    fi
    return 0
}

# ts_latest_cache_due — rc 0 when a network check is due (no cache, expired,
# or a failed attempt older than TS_LATEST_FAIL_TTL). A clock step backwards
# (negative age) counts as due.
ts_latest_cache_due() {
    local ok
    local checked
    local age
    local ttl
    ok=$(_ts_cache_field ok) || return 0
    checked=$(_ts_num "$(_ts_cache_field checked_at)")
    [ "$checked" -gt 0 ] || return 0
    age=$(( $(_ts_now) - checked ))
    [ "$age" -ge 0 ] || return 0
    ttl="$TS_LATEST_TTL"
    [ "$ok" = "true" ] || ttl="$TS_LATEST_FAIL_TTL"
    [ "$age" -ge "$ttl" ]
}

# --- staging -----------------------------------------------------------------

# ts_stage_official <dir> — download, verify and extract the latest official
# build into <dir> (RAM). Sets TS_STAGE_DIR (holds tailscale + tailscaled) and
# TS_STAGE_VER. Writes progress; rc 1 after a progress error.
ts_stage_official() {
    local dir
    local tgz
    local ext
    local url
    local free_kb
    local mem_kb
    local tgz_kb
    local expected
    local actual
    local src
    local v
    dir="$1"
    TS_STAGE_DIR=""
    TS_STAGE_VER=""

    if [ "$(uname -m 2>/dev/null)" != "aarch64" ]; then
        _ts_fail unsupported_arch "This device is not supported by the official Tailscale build" "$(uname -m 2>/dev/null)"
        return 1
    fi
    if [ -z "$dir" ] || ! qm_root_dir "$dir" 0700; then
        _ts_fail "$(_ts_generic_code)" "Cannot prepare work directory"
        return 1
    fi
    tgz="$dir/dl.tgz"
    ext="$dir/extract"
    rm -rf "$tgz" "$ext"

    ts_progress running "Checking disk space..."
    free_kb=$(_ts_df_free_kb "$dir")
    mem_kb=$(_ts_mem_avail_kb)
    if [ "$free_kb" -lt 102400 ] || [ "$mem_kb" -lt 131072 ]; then
        _ts_fail insufficient_space "Not enough free memory to download Tailscale" "Need about 100 MB free"
        return 1
    fi

    # The update path already resolved the version this run; reuse it.
    if [ -z "$TS_LATEST_VER" ] || [ -z "$TS_LATEST_TARBALL" ]; then
        ts_progress running "Resolving latest version..."
        if ! ts_latest_refresh; then
            _ts_fail update_check_failed "Could not resolve latest Tailscale version" "pkgs.tailscale.com unreachable or response format changed"
            return 1
        fi
    fi
    url="$TS_PKGS_BASE/$TS_LATEST_TARBALL"

    ts_progress running "Downloading Tailscale $TS_LATEST_VER..."
    if ! curl -fsSL --proto =https --proto-redir =https --retry 2 --max-time 600 -o "$tgz" "$url"; then
        rm -f "$tgz"
        _ts_fail "$(_ts_generic_code)" "Download failed" "Check internet connection and retry"
        return 1
    fi

    ts_progress running "Verifying download..."
    expected=$(curl -fsSL --proto =https --proto-redir =https --retry 2 --max-time 20 "${url}.sha256" 2>/dev/null \
        | head -n 1 | awk '{print $1}' | tr 'A-F' 'a-f')
    case "$expected" in
        ''|*[!0-9a-f]*) expected="" ;;
    esac
    [ "${#expected}" -eq 64 ] || expected=""
    actual=$(sha256sum "$tgz" 2>/dev/null | awk '{print $1}')
    if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
        rm -f "$tgz"
        _ts_fail checksum_mismatch "Download could not be verified" "Checksum missing or does not match"
        return 1
    fi

    # Extraction needs roughly 2.5x the tarball; check against the real size.
    tgz_kb=$(_ts_size_kb "$tgz")
    free_kb=$(_ts_df_free_kb "$dir")
    if [ "$free_kb" -lt $((tgz_kb * 3)) ]; then
        rm -f "$tgz"
        _ts_fail insufficient_space "Not enough free memory to extract Tailscale"
        return 1
    fi

    ts_progress running "Extracting..."
    mkdir -p "$ext"
    if ! tar -xzf "$tgz" -C "$ext" 2>/dev/null; then
        rm -rf "$ext"
        mkdir -p "$ext"
        if ! gzip -dc "$tgz" 2>/dev/null | tar -x -C "$ext" 2>/dev/null; then
            rm -rf "$tgz" "$ext"
            _ts_fail "$(_ts_generic_code)" "Extraction failed"
            return 1
        fi
    fi
    rm -f "$tgz"

    src=$(find "$ext" -maxdepth 1 -type d -name 'tailscale_*' 2>/dev/null | head -n 1)
    [ -n "$src" ] || src="$ext"
    if [ ! -f "$src/tailscale" ] || [ ! -f "$src/tailscaled" ]; then
        rm -rf "$ext"
        _ts_fail "$(_ts_generic_code)" "Binaries not found in archive"
        return 1
    fi
    chmod 755 "$src/tailscale" "$src/tailscaled" 2>/dev/null

    v=$("$src/tailscale" version 2>/dev/null | head -n 1 | awk '{print $1}')
    if [ "$v" != "$TS_LATEST_VER" ]; then
        rm -rf "$ext"
        _ts_fail "$(_ts_generic_code)" "Downloaded build failed its self-test" "Expected $TS_LATEST_VER, got ${v:-nothing}"
        return 1
    fi
    v=$("$src/tailscaled" --version 2>/dev/null | head -n 1 | awk '{print $1}')
    if [ "$v" != "$TS_LATEST_VER" ]; then
        rm -rf "$ext"
        _ts_fail "$(_ts_generic_code)" "Downloaded build failed its self-test" "tailscaled reported ${v:-nothing}"
        return 1
    fi

    TS_STAGE_DIR="$src"
    TS_STAGE_VER="$TS_LATEST_VER"
    return 0
}

# --- space planning, swap, restore ----------------------------------------------

# ts_space_plan — pick how the old binaries are kept during an update.
#   overlay: overlay free >= new total + 16 MB; backups are hard links
#            (/usr/bin/.X.old), costing no flash.
#   tmp:     old binaries copied to RAM. The CLI is swapped first and its old
#            inode is freed; the old tailscaled inode stays allocated while
#            the daemon runs, so the overlay must hold each new file in turn:
#            free >= new CLI + 8 MB and free - new CLI + old CLI >= new daemon
#            + 8 MB. RAM must hold the copies: MemAvailable >= old total + 96 MB.
# Sets TS_SPACE_MODE. rc 1 after an insufficient_space progress error.
ts_space_plan() {
    local free_kb
    local mem_kb
    local new_cli
    local new_d
    local old_cli
    local old_d
    local after_cli
    new_cli=$(_ts_size_kb "$TS_STAGE_DIR/tailscale")
    new_d=$(_ts_size_kb "$TS_STAGE_DIR/tailscaled")
    old_cli=$(_ts_size_kb "$TS_BIN_DIR/tailscale")
    old_d=$(_ts_size_kb "$TS_BIN_DIR/tailscaled")
    free_kb=$(_ts_df_free_kb "$TS_BIN_DIR")
    mem_kb=$(_ts_mem_avail_kb)
    TS_SPACE_MODE=""
    if [ "$free_kb" -ge $((new_cli + new_d + 16384)) ]; then
        TS_SPACE_MODE="overlay"
        return 0
    fi
    after_cli=$((free_kb - new_cli + old_cli))
    if [ "$free_kb" -ge $((new_cli + 8192)) ] \
            && [ "$after_cli" -ge $((new_d + 8192)) ] \
            && [ "$mem_kb" -ge $((old_cli + old_d + 98304)) ]; then
        TS_SPACE_MODE="tmp"
        return 0
    fi
    _ts_fail insufficient_space "Not enough free space to update Tailscale" \
        "$((free_kb / 1024)) MB free on flash, $((mem_kb / 1024)) MB free memory"
    return 1
}

_ts_backup_dir() {
    printf '%s/tailscale_bak' "$(qm_run_dir 2>/dev/null)"
}

# _ts_install_one SRC NAME [DIR] — cp to DIR/.NAME.new, sync, rename over
# DIR/NAME. DIR defaults to TS_BIN_DIR.
_ts_install_one() {
    local tmp
    local dir
    dir="${3:-$TS_BIN_DIR}"
    tmp="$dir/.$2.new"
    rm -f "$tmp"
    if cp "$1" "$tmp" 2>/dev/null && chmod 755 "$tmp"; then
        # Data on flash before the name points at it (UBIFS writeback: an
        # unsynced rename can survive a power cut as a 0-byte binary).
        sync
        mv -f "$tmp" "$dir/$2" && return 0
    fi
    rm -f "$tmp"
    return 1
}

# ts_swap_binaries — back up the current binaries per TS_SPACE_MODE (overlay /
# tmp; anything else = fresh install, no backup), then install the staged
# ones. The CLI goes first so that, in tmp mode, its old inode is freed before
# the daemon's new copy is written.
ts_swap_binaries() {
    local f
    local bak
    case "$TS_SPACE_MODE" in
        overlay)
            for f in tailscale tailscaled; do
                ln -f "$TS_BIN_DIR/$f" "$TS_BIN_DIR/.$f.old" 2>/dev/null || return 1
            done
            ;;
        tmp)
            bak=$(_ts_backup_dir)
            qm_root_dir "$bak" 0700 || return 1
            for f in tailscale tailscaled; do
                cp "$TS_BIN_DIR/$f" "$bak/$f" 2>/dev/null || return 1
            done
            ;;
    esac
    TS_SWAP_PENDING=1
    for f in tailscale tailscaled; do
        _ts_install_one "$TS_STAGE_DIR/$f" "$f" || { sync; return 1; }
    done
    sync
    return 0
}

# ts_restore_binaries — put the backed-up binaries back.
ts_restore_binaries() {
    local f
    local bak
    local rc
    rc=0
    case "$TS_SPACE_MODE" in
        overlay)
            for f in tailscale tailscaled; do
                if [ -f "$TS_BIN_DIR/.$f.old" ]; then
                    mv -f "$TS_BIN_DIR/.$f.old" "$TS_BIN_DIR/$f" || rc=1
                fi
            done
            ;;
        tmp)
            # The running new tailscaled pins its inode, and the overlay was
            # already too tight to hold both builds: stop the daemon and drop
            # the new file first, or the copy back can fail with ENOSPC. The
            # caller restarts Tailscale afterwards.
            bak=$(_ts_backup_dir)
            if [ -x /etc/init.d/tailscale ]; then
                /etc/init.d/tailscale stop >/dev/null 2>&1
            else
                killall tailscaled 2>/dev/null
            fi
            for f in tailscale tailscaled; do
                if [ -f "$bak/$f" ]; then
                    rm -f "$TS_BIN_DIR/$f" "$TS_BIN_DIR/.$f.new"
                    _ts_install_one "$bak/$f" "$f" || rc=1
                fi
            done
            ;;
        tiny)
            # Same reasoning as tmp: stop first so the new binary's inode is
            # freed before the old one is written back. The package's CLI is
            # a symlink to the daemon; recreate it if the upgrade lost it.
            bak=$(_ts_backup_dir)
            [ -x /etc/init.d/tailscale ] && /etc/init.d/tailscale stop >/dev/null 2>&1
            killall tailscaled 2>/dev/null
            if [ -f "$bak/tailscaled" ]; then
                rm -f "$TS_TINY_BIN_DIR/tailscaled" "$TS_TINY_BIN_DIR/.tailscaled.new"
                _ts_install_one "$bak/tailscaled" tailscaled "$TS_TINY_BIN_DIR" || rc=1
            else
                rc=1
            fi
            [ -e "$TS_BIN_DIR/tailscale" ] || ln -sf ../sbin/tailscaled "$TS_BIN_DIR/tailscale" 2>/dev/null
            ;;
    esac
    sync
    TS_SWAP_PENDING=0
    return "$rc"
}

# _ts_restart_old <ver> — after a rollback: restart when the daemon ran
# before the update, then verify the old build (best effort, logged only).
_ts_restart_old() {
    [ "$TS_WAS_RUNNING" = "1" ] || return 0
    /etc/init.d/tailscale restart >/dev/null 2>&1
    if ts_wait_healthy "$1" 20; then
        echo "Tailscale $1 is running again"
    else
        echo "Tailscale $1 restarted but did not report healthy within 20 s"
    fi
}

# _ts_md5 FILE — md5 of FILE, "" if missing.
_ts_md5() {
    md5sum "$1" 2>/dev/null | awk '{print $1}'
}

# _ts_ino FILE — inode number, "" if missing.
_ts_ino() {
    ls -i "$1" 2>/dev/null | awk '{print $1}'
}

# ts_recover_interrupted — an update that died after swapping (power cut,
# kill -9) leaves the old build as /usr/bin/.X.old hard links. Put it back
# and clear .new leftovers. Call only while no other worker holds the lock.
# rc 0 when something was restored.
ts_recover_interrupted() {
    local f
    local old
    local restored
    restored=1
    for f in tailscale tailscaled; do
        old="$TS_BIN_DIR/.$f.old"
        [ -f "$old" ] || continue
        if [ "$(_ts_ino "$old")" = "$(_ts_ino "$TS_BIN_DIR/$f")" ]; then
            # Same inode: the swap never happened (rename onto a hard link of
            # itself is a no-op that keeps both names), so just drop the link.
            rm -f "$old"
        elif mv -f "$old" "$TS_BIN_DIR/$f"; then
            restored=0
            echo "Restored the previous $f after an interrupted update"
        fi
    done
    rm -f "$TS_BIN_DIR/.tailscale.new" "$TS_BIN_DIR/.tailscaled.new"
    sync
    return "$restored"
}

ts_drop_backup() {
    rm -f "$TS_BIN_DIR/.tailscale.old" "$TS_BIN_DIR/.tailscaled.old" \
        "$TS_BIN_DIR/.tailscale.new" "$TS_BIN_DIR/.tailscaled.new" \
        "$TS_TINY_BIN_DIR/.tailscaled.new"
    rm -rf "$(_ts_backup_dir)"
    TS_SWAP_PENDING=0
}

# ts_wait_healthy <ver> <secs> [nodaemon] — rc 0 once the CLI reports <ver>
# and (unless nodaemon) tailscaled runs and `tailscale status --json` parses.
ts_wait_healthy() {
    local want
    local secs
    local n
    local v
    local st
    want="$1"
    secs=$(_ts_num "$2")
    n=0
    while [ "$n" -lt "$secs" ]; do
        if [ "$TS_TEST_FAIL_HEALTH" != "1" ]; then
            v=$("$TS_BIN_DIR/tailscale" version 2>/dev/null | head -n 1 | awk '{print $1}')
            if [ "$v" = "$want" ]; then
                [ "$3" = "nodaemon" ] && return 0
                if pidof tailscaled >/dev/null 2>&1; then
                    if command -v timeout >/dev/null 2>&1; then
                        st=$(timeout 5 "$TS_BIN_DIR/tailscale" status --json 2>/dev/null)
                    else
                        st=$("$TS_BIN_DIR/tailscale" status --json 2>/dev/null)
                    fi
                    [ -n "$st" ] && printf '%s' "$st" | jq -e . >/dev/null 2>&1 && return 0
                fi
            fi
        fi
        sleep 1
        n=$((n + 1))
    done
    return 1
}

# --- UCI parity --------------------------------------------------------------

# Seed tailscale.settings.service_enabled=0 when absent. `uci set pkg=type`
# cannot create a missing /etc/config file on this device, so bootstrap it.
ts_seed_uci_settings() {
    if [ ! -f /etc/config/tailscale ]; then
        printf 'config settings '\''settings'\''\n\toption service_enabled '\''0'\''\n' \
            | qm_durable_write /etc/config/tailscale
    elif ! uci -q get tailscale.settings >/dev/null 2>&1; then
        uci -q set tailscale.settings=settings 2>/dev/null
    fi
    uci -q get tailscale.settings.service_enabled >/dev/null 2>&1 \
        || uci -q set tailscale.settings.service_enabled='0'
    uci -q commit tailscale 2>/dev/null
}

# --- worker lifecycle ----------------------------------------------------------

_ts_work_dir() {
    printf '%s/tailscale_dl' "$(qm_run_dir 2>/dev/null)"
}

# EXIT trap of a worker: a swap interrupted half way is rolled back before
# the RAM backup and the lock go away.
_ts_worker_exit() {
    if [ "$TS_SWAP_PENDING" = "1" ] && [ -n "$TS_SPACE_MODE" ]; then
        ts_restore_binaries
        hash -r 2>/dev/null
        # The Tiny postinst re-enabled boot; put the user's choice back.
        if [ "$TS_SPACE_MODE" = "tiny" ] && [ -n "$TS_TINY_BOOT" ]; then
            _ts_tiny_boot_set "$TS_TINY_BOOT"
        fi
        _ts_restart_old "$TS_OLD_VER"
    fi
    rm -rf "$(_ts_work_dir)"
    [ "$TS_KEEP_BACKUP" = "1" ] || rm -rf "$(_ts_backup_dir)"
    ts_lock_release
}

_ts_worker_begin() {
    TS_OP="$1"
    TS_SWAP_PENDING=0
    TS_SPACE_MODE=""
    TS_KEEP_BACKUP=0
    TS_WAS_RUNNING=0
    TS_TINY_BOOT=""
    TS_OLD_VER=""
    TS_LATEST_VER=""
    TS_LATEST_TARBALL=""
    if ! qm_run_dir >/dev/null 2>&1; then
        _ts_fail "$(_ts_generic_code)" "Cannot prepare the QManager run directory"
        return 1
    fi
    if ! ts_lock_acquire "$1"; then
        # Only report when no other live worker owns the progress file (the
        # holder is the CGI that spawned us, or nobody); never clobber a run.
        _tsb_holder=$(ts_lock_holder)
        if [ -z "$_tsb_holder" ] || [ "$_tsb_holder" = "$$" ]; then
            _ts_fail "$(_ts_generic_code)" "Could not start the Tailscale $1" "Install lock unavailable"
        else
            echo "Another Tailscale install or update is already running"
        fi
        return 1
    fi
    trap '_ts_worker_exit' EXIT
    trap 'exit 1' INT TERM
    return 0
}

# --- entry points --------------------------------------------------------------
# Each runs its body under the lock, then cleans up explicitly (the EXIT trap
# covers a worker killed mid-way). rc 0 on success.

# ts_do_install <official|tiny>
ts_do_install() {
    local rc
    TS_SOURCE="official"
    [ "$1" = "tiny" ] && TS_SOURCE="tiny"
    _ts_worker_begin install || return 1
    if [ "$TS_SOURCE" = "tiny" ]; then
        _ts_install_body_tiny
    else
        _ts_install_body
    fi
    rc=$?
    _ts_worker_exit
    trap - EXIT INT TERM
    return "$rc"
}

# ts_do_update — the source follows the installed variant.
ts_do_update() {
    local rc
    TS_SOURCE="official"
    [ "$(ts_variant)" = "tiny" ] && TS_SOURCE="tiny"
    _ts_worker_begin update || return 1
    if [ "$TS_SOURCE" = "tiny" ]; then
        _ts_update_body_tiny
    else
        _ts_update_body
    fi
    rc=$?
    _ts_worker_exit
    trap - EXIT INT TERM
    return "$rc"
}

_ts_install_body() {
    local work
    local need
    local free_kb
    work=$(_ts_work_dir)
    ts_recover_interrupted

    ts_stage_official "$work" || return 1

    need=$(( $(_ts_size_kb "$TS_STAGE_DIR/tailscale") + $(_ts_size_kb "$TS_STAGE_DIR/tailscaled") + 8192 ))
    free_kb=$(_ts_df_free_kb "$TS_BIN_DIR")
    if [ "$free_kb" -lt "$need" ]; then
        _ts_fail insufficient_space "Not enough free space on flash" "Need $((need / 1024)) MB, $((free_kb / 1024)) MB free"
        return 1
    fi

    ts_progress running "Installing binaries..."
    TS_SPACE_MODE=""
    if ! ts_swap_binaries; then
        rm -f "$TS_BIN_DIR/tailscale" "$TS_BIN_DIR/tailscaled" \
            "$TS_BIN_DIR/.tailscale.new" "$TS_BIN_DIR/.tailscaled.new"
        sync
        TS_SWAP_PENDING=0
        _ts_fail install_failed "Failed to install binaries to /usr/bin"
        return 1
    fi
    TS_SWAP_PENDING=0
    rm -rf "$work"
    hash -r 2>/dev/null

    ts_progress running "Writing service..."
    mkdir -p /etc/tailscale
    if ! command -v qm_write_ts_initd >/dev/null 2>&1 || ! qm_write_ts_initd; then
        _ts_fail install_failed "Failed to write Tailscale service" "tailscale_initd.sh lib missing"
        return 1
    fi
    printf 'official\n' | qm_durable_write "$TS_INSTALL_MARKER"
    ts_seed_uci_settings

    if command -v ts_net_enabled >/dev/null 2>&1 && ts_net_enabled; then
        ts_progress running "Applying network settings..."
        ts_net_apply
    fi

    ts_progress complete "Tailscale $TS_STAGE_VER installed successfully"
    return 0
}

_ts_update_body() {
    local work
    local installed
    local was_running
    local hc_mode
    case "$(ts_variant)" in
        official) : ;;
        none) _ts_fail not_installed "Tailscale is not installed"; return 1 ;;
        *) _ts_fail legacy_build "This Tailscale build cannot be updated here" "Uninstall it, then install the official build"; return 1 ;;
    esac
    work=$(_ts_work_dir)
    ts_recover_interrupted && hash -r 2>/dev/null
    installed=$(ts_installed_version)
    TS_OLD_VER="$installed"

    ts_progress running "Checking for updates..."
    if ! ts_latest_refresh; then
        _ts_fail update_check_failed "Could not resolve latest Tailscale version" "pkgs.tailscale.com unreachable or response format changed"
        return 1
    fi
    if ! ts_version_gt "$TS_LATEST_VER" "$installed"; then
        _ts_fail up_to_date "Tailscale is already up to date" "$installed"
        return 1
    fi

    ts_stage_official "$work" || return 1
    if ! ts_version_gt "$TS_STAGE_VER" "$installed"; then
        _ts_fail up_to_date "Tailscale is already up to date" "$installed"
        return 1
    fi

    ts_space_plan || return 1

    was_running=0
    pidof tailscaled >/dev/null 2>&1 && was_running=1
    TS_WAS_RUNNING="$was_running"

    ts_progress running "Installing Tailscale $TS_STAGE_VER..."
    if ! ts_swap_binaries; then
        if [ "$TS_SWAP_PENDING" = "1" ]; then
            ts_restore_binaries
            hash -r 2>/dev/null
            # tmp-mode restore stops the daemon; bring it back.
            [ "$TS_SPACE_MODE" = "tmp" ] && _ts_restart_old "$installed"
        fi
        ts_drop_backup
        _ts_fail update_failed "Failed to install the new binaries" "Tailscale $installed was kept"
        return 1
    fi
    rm -rf "$work"
    hash -r 2>/dev/null

    hc_mode="nodaemon"
    if [ "$was_running" = "1" ]; then
        hc_mode=""
        ts_progress running "Restarting Tailscale..."
        /etc/init.d/tailscale restart >/dev/null 2>&1
    fi

    ts_progress running "Checking Tailscale..."
    if ! ts_wait_healthy "$TS_STAGE_VER" 30 $hc_mode; then
        ts_progress running "Update failed its health check, rolling back..."
        if ! ts_restore_binaries; then
            # Keep whatever backup is left for manual recovery.
            TS_KEEP_BACKUP=1
            _ts_fail update_failed "Update failed and the previous version could not be fully restored"
            return 1
        fi
        hash -r 2>/dev/null
        _ts_restart_old "$installed"
        ts_drop_backup
        _ts_fail update_rolled_back "Update failed, Tailscale $installed was restored"
        return 1
    fi

    TS_SWAP_PENDING=0
    ts_drop_backup
    if command -v ts_net_enabled >/dev/null 2>&1 && ts_net_enabled; then
        ts_net_ensure_rules
    fi
    ts_progress complete "Tailscale updated to $TS_STAGE_VER"
    return 0
}

# --- Tiny source (opkg) --------------------------------------------------------

# _ts_opkg_busy — rc 0 while another opkg run holds its lock. opkg unlinks the
# file on exit; a file left by a crashed run is not busy if it can be locked.
_ts_opkg_busy() {
    [ -f /var/lock/opkg.lock ] || return 1
    command -v flock >/dev/null 2>&1 || return 0
    ! flock -n /var/lock/opkg.lock true 2>/dev/null
}

# _ts_opkg_wait — wait up to 30 s for another opkg run to finish.
_ts_opkg_wait() {
    local n
    n=0
    while _ts_opkg_busy && [ "$n" -lt 30 ]; do
        sleep 1
        n=$((n + 1))
    done
    ! _ts_opkg_busy
}

# _ts_opkg_refresh — opkg update, then require the Tiny package to resolve.
# A partial failure (an unrelated mirror down) is fine once Cameron's feed
# loaded; opkg rejects a list whose signature does not verify.
_ts_opkg_refresh() {
    if ! _ts_opkg_wait; then
        _ts_fail "$(_ts_generic_code)" "Another package operation is running" "Try again in a minute"
        return 1
    fi
    ts_progress running "Updating package lists..."
    opkg update || echo "Some package lists could not be updated"
    if ! opkg info "$TS_TINY_PKG" 2>/dev/null | grep -q "^Package: $TS_TINY_PKG"; then
        _ts_fail feed_unavailable "Could not load the Tiny build's package list" "Check the internet connection and retry"
        return 1
    fi
    return 0
}

# _ts_tiny_boot_get — 1 when Tailscale starts on boot, else 0 (UCI flag
# first, like the CGI's get_boot_enabled; init.d enabled as the fallback).
_ts_tiny_boot_get() {
    local v
    v=$(uci -q get tailscale.settings.service_enabled 2>/dev/null)
    case "$v" in
        1) printf '1'; return 0 ;;
        0) printf '0'; return 0 ;;
    esac
    if [ -x /etc/init.d/tailscale ] && /etc/init.d/tailscale enabled; then
        printf '1'
    else
        printf '0'
    fi
}

# _ts_tiny_boot_set 0|1 — init.d enable/disable plus the UCI flag, in lockstep.
_ts_tiny_boot_set() {
    if [ -x /etc/init.d/tailscale ]; then
        if [ "$1" = "1" ]; then
            /etc/init.d/tailscale enable >/dev/null 2>&1
        else
            /etc/init.d/tailscale disable >/dev/null 2>&1
        fi
    fi
    if uci -q get tailscale.settings >/dev/null 2>&1; then
        uci -q set tailscale.settings.service_enabled="$1" 2>/dev/null
        uci -q commit tailscale 2>/dev/null
    fi
}

# _ts_tiny_daemon_stale — rc 0 when a running tailscaled still executes a
# binary that has since been replaced on flash.
_ts_tiny_daemon_stale() {
    local p
    for p in $(pidof tailscaled 2>/dev/null); do
        case "$p" in ''|*[!0-9]*) continue ;; esac
        ls -l "/proc/$p/exe" 2>/dev/null | grep -q '(deleted)' && return 0
    done
    return 1
}

_ts_install_body_tiny() {
    local free_kb
    local tmp_kb
    local v
    if ! ts_tiny_available; then
        _ts_fail feed_unavailable "The Tiny build is not available on this device"
        return 1
    fi
    ts_progress running "Checking disk space..."
    free_kb=$(_ts_df_free_kb "$TS_TINY_BIN_DIR")
    tmp_kb=$(_ts_df_free_kb /tmp)
    if [ "$free_kb" -lt 28672 ]; then
        _ts_fail insufficient_space "Not enough free space on flash" "Need 28 MB, $((free_kb / 1024)) MB free"
        return 1
    fi
    if [ "$tmp_kb" -lt 32768 ]; then
        _ts_fail insufficient_space "Not enough free memory to download Tailscale" "Need about 32 MB free"
        return 1
    fi

    _ts_opkg_refresh || return 1

    ts_progress running "Installing the Tiny build..."
    if ! opkg install "$TS_TINY_PKG"; then
        opkg remove "$TS_TINY_PKG" >/dev/null 2>&1
        _ts_fail install_failed "The package manager could not install the Tiny build"
        return 1
    fi
    hash -r 2>/dev/null
    if [ ! -x "$TS_TINY_BIN_DIR/tailscaled" ] || ! command -v tailscale >/dev/null 2>&1; then
        opkg remove "$TS_TINY_PKG" >/dev/null 2>&1
        _ts_fail install_failed "Package installed but Tailscale was not found"
        return 1
    fi

    mkdir -p /etc/tailscale
    printf 'tiny\n' | qm_durable_write "$TS_INSTALL_MARKER"
    v=$(ts_installed_version)
    ts_progress complete "Tailscale ${v:-Tiny} installed successfully"
    return 0
}

_ts_update_body_tiny() {
    local installed
    local free_kb
    local mem_kb
    local old_kb
    local was_running
    local boot
    local bak
    local new_v
    local hc_mode
    local opkg_rc
    installed=$(ts_tiny_pkg_version)
    TS_OLD_VER=$(ts_installed_version)
    if [ -z "$installed" ]; then
        _ts_fail update_failed "Could not read the installed Tiny build's version"
        return 1
    fi

    ts_progress running "Checking for updates..."
    if ! ts_latest_refresh; then
        _ts_fail update_check_failed "Could not check the Tiny build's package feed" "The feed is unreachable or its format changed"
        return 1
    fi
    if [ "$TS_TEST_FORCE_UPDATE" != "1" ] && ! ts_version_gt "$TS_LATEST_VER" "$installed"; then
        _ts_fail up_to_date "Tailscale is already up to date" "$installed"
        return 1
    fi

    # Flash: the new binary is written while the running daemon still pins
    # the old inode. RAM: the rollback copy plus opkg's download.
    free_kb=$(_ts_df_free_kb "$TS_TINY_BIN_DIR")
    mem_kb=$(_ts_mem_avail_kb)
    old_kb=$(_ts_size_kb "$TS_TINY_BIN_DIR/tailscaled")
    if [ "$free_kb" -lt 28672 ] || [ "$mem_kb" -lt $((old_kb + 98304)) ]; then
        _ts_fail insufficient_space "Not enough free space to update Tailscale" \
            "$((free_kb / 1024)) MB free on flash, $((mem_kb / 1024)) MB free memory"
        return 1
    fi

    _ts_opkg_refresh || return 1

    was_running=0
    pidof tailscaled >/dev/null 2>&1 && was_running=1
    TS_WAS_RUNNING="$was_running"
    boot=$(_ts_tiny_boot_get)
    TS_TINY_BOOT="$boot"

    bak=$(_ts_backup_dir)
    if ! qm_root_dir "$bak" 0700 || ! cp "$TS_TINY_BIN_DIR/tailscaled" "$bak/tailscaled" 2>/dev/null; then
        rm -rf "$bak"
        _ts_fail update_failed "Could not keep a copy of the current version" "Tailscale ${TS_OLD_VER} was kept"
        return 1
    fi
    TS_SPACE_MODE="tiny"
    TS_SWAP_PENDING=1

    ts_progress running "Installing Tailscale $TS_LATEST_VER..."
    opkg_rc=0
    if [ "$TS_TEST_FORCE_UPDATE" = "1" ]; then
        opkg install --force-reinstall "$TS_TINY_PKG" || opkg_rc=1
    else
        opkg install "$TS_TINY_PKG" || opkg_rc=1
        # rc 0 with the old package still recorded: opkg saw nothing newer
        # (its lists did not load). Not an update.
        [ "$(ts_tiny_pkg_version)" = "$TS_LATEST_VER" ] || opkg_rc=1
    fi
    # Whatever opkg did, its postinst enabled boot and started the daemon:
    # put the user's choice back.
    hash -r 2>/dev/null
    _ts_tiny_boot_set "$boot"
    if [ "$was_running" = "0" ] && [ -x /etc/init.d/tailscale ]; then
        /etc/init.d/tailscale stop >/dev/null 2>&1
    fi

    hc_mode="nodaemon"
    if [ "$was_running" = "1" ]; then
        hc_mode=""
        if ! pidof tailscaled >/dev/null 2>&1; then
            /etc/init.d/tailscale start >/dev/null 2>&1
        elif _ts_tiny_daemon_stale; then
            # The CLI is the same multicall binary, so only the daemon's exe
            # can tell an old process apart from the new one.
            /etc/init.d/tailscale restart >/dev/null 2>&1
        fi
    fi

    # opkg failed before touching the binary (download, signature, space):
    # nothing to roll back.
    if [ "$opkg_rc" = "1" ] && [ -f "$TS_TINY_BIN_DIR/tailscaled" ] \
            && [ "$(_ts_md5 "$bak/tailscaled")" = "$(_ts_md5 "$TS_TINY_BIN_DIR/tailscaled")" ]; then
        TS_SWAP_PENDING=0
        ts_drop_backup
        _ts_fail update_failed "The package manager could not install the update" "Tailscale $TS_OLD_VER was kept"
        return 1
    fi
    new_v=$(ts_installed_version)

    ts_progress running "Checking Tailscale..."
    if [ "$opkg_rc" = "1" ] || [ -z "$new_v" ] || ! ts_wait_healthy "$new_v" 30 $hc_mode; then
        ts_progress running "Update failed its health check, rolling back..."
        if ! ts_restore_binaries; then
            TS_KEEP_BACKUP=1
            _ts_fail update_failed "Update failed and the previous version could not be fully restored"
            return 1
        fi
        hash -r 2>/dev/null
        _ts_tiny_boot_set "$boot"
        _ts_restart_old "$TS_OLD_VER"
        ts_drop_backup
        _ts_fail update_rolled_back "Update failed, Tailscale $TS_OLD_VER was restored"
        return 1
    fi

    TS_SWAP_PENDING=0
    ts_drop_backup
    ts_progress complete "Tailscale updated to $new_v"
    return 0
}
