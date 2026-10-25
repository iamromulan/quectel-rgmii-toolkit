#!/bin/sh
# =============================================================================
# QManager Installer (v2) — filesystem-driven, crash-resilient
# =============================================================================
# Installs QManager frontend + backend onto a barebone OpenWRT device running
# RM551E-GL modem firmware. Designed to work without extra opkg dependencies
# beyond what this script installs itself.
#
# Design invariants:
#   1. POSIX /bin/sh only (no bashisms, no arrays, no [[ ]])
#   2. curl-only HTTP (no wget, no uclient-fetch fallbacks)
#   3. Service lists are filesystem-driven — zero hardcoded script names
#      except for the small UCI-gated list (user-controlled services).
#   4. Two-phase VERSION write (pending -> final) so partial installs leave
#      the old VERSION intact and the update CGI can detect the failure.
#   5. Every visible line also goes to /tmp/qmanager_install.log with a
#      timestamp and severity, for easy post-mortem debugging.
#
# Archive layout at INSTALL_DIR:
#   out/                        Next.js static export (frontend)
#   scripts/                    Backend shell tree
#     etc/init.d/               Init.d service scripts
#     etc/qmanager/             Default config files
#     usr/bin/                  Daemons and utilities (qmanager_*, qcmd, qsms, ...)
#     usr/lib/qmanager/         Shared shell libraries
#     www/cgi-bin/quecmanager/  CGI API endpoints
#   dependencies/               Bundled binaries (qmanager_atd)
#   install.sh                  This script
#
# Usage:
#   cd /tmp && tar xzf qmanager.tar.gz
#   cd qmanager_install && sh install.sh
#
# Flags:
#   --frontend-only    Only install frontend files
#   --backend-only     Only install backend scripts
#   --skip-packages    Skip opkg package install (OTA path uses this)
#   --no-enable        Do not enable init.d services
#   --no-start         Do not start services after install
#   --no-reboot        Do not reboot after install (OTA path uses this)
#   --force            Skip modem firmware detection
#   --ignore-package   Install over an opkg-managed (sdxpinn-qmanager) install
#   --configure        Package mode: configure files opkg already placed
#                      (the ipk postinst runs this; never prompts or reboots)
#   --help, -h         Show this help
#
# Package (ipk) builds also embed this script as the preinst, entered through
# QM_INSTALL_ENTRY=ipk_preinst (see ipk_preinst below and build-ipk.sh).
# =============================================================================

set -e

# --- Configuration -----------------------------------------------------------

VERSION="v0.1.35"
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="/tmp/qmanager_install.log"

# Target filesystem paths
WWW_ROOT="/www"
CGI_DIR="/www/cgi-bin/quecmanager"
LIB_DIR="/usr/lib/qmanager"
# install_tree staging area (same overlay as /www, outside the web root)
TREE_STAGE_ROOT="/usr/lib/.qmanager_stage"
BIN_DIR="/usr/bin"
INITD_DIR="/etc/init.d"
CONF_DIR="/etc/qmanager"
UPDATES_DIR="/etc/qmanager/updates"
SESSION_DIR="/tmp/qmanager_sessions"
BACKUP_DIR="/etc/qmanager/backups"
VERSION_FILE="/etc/qmanager/VERSION"
VERSION_PENDING="/etc/qmanager/VERSION.pending"

# Source directories inside the tarball
SRC_FRONTEND="$INSTALL_DIR/out"
SRC_SCRIPTS="$INSTALL_DIR/scripts"
SRC_DEPS="$INSTALL_DIR/dependencies"

# Package (ipk) install. opkg owns the payload files, so --configure reads the
# shipped file list (manifest, root-relative paths) instead of a source tree,
# and default configs from defaults/. IPK_INFO exists once opkg has the package.
IPK_PACKAGE="sdxpinn-qmanager"
IPK_SHARE_DIR="/usr/share/qmanager"
IPK_MANIFEST="$IPK_SHARE_DIR/manifest"
IPK_DEFAULTS="$IPK_SHARE_DIR/defaults"
IPK_INFO="/usr/lib/opkg/info/$IPK_PACKAGE.control"
# Services running before preinst stopped them, handed to the postinst
IPK_RUNNING_FILE="/tmp/qmanager_ipk_running"
# Read (and cleared) by system/pending_reboot.sh to raise the reboot banner
IPK_REBOOT_FLAG="/tmp/qmanager_pending_reboot_package"

# 1 while running inside opkg (preinst / --configure): opkg holds its lock, so
# nothing here may call opkg, prompt, or reboot.
IN_OPKG=0
CONFIGURE=0

# Packages
# Note: coreutils-timeout is required even though BusyBox ships a `timeout`
# applet — barebone OpenWRT builds (like OEM modem firmware) often strip
# applets at compile time, so we can't assume BusyBox `timeout` is present.
# The installer's run_capture_timeout helper relies on it to bound every AT
# probe and smoke test, and other scripts use it as a safety cap. Cheap
# guarantee.
REQUIRED_PACKAGES="jq curl coreutils-timeout ethtool"
OPTIONAL_PACKAGES="msmtp ookla-speedtest"
# Removed before install: they open /dev/smd11 and fight the AT broker for it
CONFLICT_PACKAGES="sms-tool socat-at-bridge socat"

# UCI-gated services — only enabled if a prior install had them enabled.
# Everything else is enabled unconditionally. This is the ONLY hardcoded
# service list in this script.
UCI_GATED_SERVICES="qmanager_tower_failover qmanager_watchcat qmanager_dpi qmanager_sms_forward"

# Expected modem firmware signature (after normalization: upper + alnum only)
REQUIRED_FIRMWARE="RM551EGL"

# Watchcat maintenance lock — touched at the start of stop_services and
# released at the end of install (or on EXIT trap). When this file exists,
# qmanager_watchcat enters LOCKED state and skips all connectivity checks,
# which prevents it from observing install-induced disruption (services
# stopping, modem state changes) and escalating to a Tier 4 system reboot
# mid-install.
WATCHCAT_LOCK="/tmp/qmanager_watchcat.lock"

# Services that were running when stop_services ran (space-separated names).
# start_services restarts them so a --no-reboot install does not leave an
# enabled daemon (e.g. qmanager_dpi) down until the next reboot.
RUNNING_BEFORE_STOP=""

# --- Colors & Icons ----------------------------------------------------------

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    DIM=''
    NC=''
fi

ICO_OK='✓'
ICO_WARN='⚠'
ICO_ERR='✗'
ICO_STEP='▶'

# --- Logging -----------------------------------------------------------------
# All user-visible output mirrors to LOG_FILE with timestamps. The log is
# truncated at the start of each install run so it always reflects the most
# recent attempt.

log_init() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    # The postinst appends, so one log holds the whole package install.
    [ "$CONFIGURE" = "1" ] || : > "$LOG_FILE" 2>/dev/null || true
    _log_raw "=== QManager install started at $(date '+%Y-%m-%d %H:%M:%S') (version=$VERSION) ==="
}

_log_raw() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

info() {
    _log_raw "[INFO ] $1"
    printf "    ${GREEN}${ICO_OK}${NC}  %s\n" "$1"
}

warn() {
    _log_raw "[WARN ] $1"
    printf "    ${YELLOW}${ICO_WARN}${NC}  %s\n" "$1"
}

error() {
    _log_raw "[ERROR] $1"
    printf "    ${RED}${ICO_ERR}${NC}  %s\n" "$1"
}

die() {
    error "$1"
    printf "\n  ${RED}${BOLD}Installation failed.${NC}\n" >&2
    printf "  See %s for details.\n\n" "$LOG_FILE" >&2
    exit 1
}

# --- Progress Tracking -------------------------------------------------------

TOTAL_STEPS=1
CURRENT_STEP=0

_draw_bar() {
    local curr="$1" tot="$2" w="${3:-20}"
    local fill=$(( curr * w / tot ))
    local bar="" i=0
    while [ "$i" -lt "$w" ]; do
        if [ "$i" -lt "$fill" ]; then
            bar="${bar}█"
        else
            bar="${bar}░"
        fi
        i=$(( i + 1 ))
    done
    printf "%s" "$bar"
}

step() {
    CURRENT_STEP=$(( CURRENT_STEP + 1 ))
    local pct=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    _log_raw ""
    _log_raw "=== Step $CURRENT_STEP/$TOTAL_STEPS: $1 ==="
    printf "\n"
    if [ -t 1 ]; then
        printf "  ${DIM}[%s  %3d%%  Step %d/%d]${NC}\n" \
            "$(_draw_bar "$CURRENT_STEP" "$TOTAL_STEPS")" \
            "$pct" "$CURRENT_STEP" "$TOTAL_STEPS"
    fi
    printf "  ${BLUE}${BOLD}${ICO_STEP}${NC}${BOLD} %s${NC}\n" "$1"
}

# --- Shell Helpers -----------------------------------------------------------

# Run a command with a rotating spinner on TTY, silent otherwise. Output and
# errors are always appended to LOG_FILE.
run_with_spinner() {
    local label="$1"; shift
    local rc=0

    if [ ! -t 1 ]; then
        "$@" >>"$LOG_FILE" 2>&1 || rc=$?
        return "$rc"
    fi

    "$@" >>"$LOG_FILE" 2>&1 &
    local cpid=$! i=0 f
    while kill -0 "$cpid" 2>/dev/null; do
        case $(( i % 3 )) in
            0) f='|' ;; 1) f='/' ;; *) f='-' ;;
        esac
        printf "\r    ${CYAN}%s${NC}  %s " "$f" "$label"
        i=$(( i + 1 ))
        sleep 1
    done
    wait "$cpid"
    rc=$?
    printf "\r\033[2K"
    return "$rc"
}

# Capture stdout of a command with a hard timeout. Uses `timeout` when
# available, otherwise a simple poll loop.
run_capture_timeout() {
    local seconds="$1"; shift
    local out_file="/tmp/qm_tmo_out.$$"
    local rc=0 pid="" i=0

    rm -f "$out_file"

    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@" >"$out_file" 2>/dev/null || rc=$?
    else
        "$@" >"$out_file" 2>/dev/null &
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            if [ "$i" -ge "$seconds" ]; then
                kill "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                rc=124
                break
            fi
            i=$(( i + 1 ))
            sleep 1
        done
        if [ "$rc" -ne 124 ]; then
            wait "$pid" 2>/dev/null
            rc=$?
        fi
    fi

    [ -f "$out_file" ] && cat "$out_file"
    rm -f "$out_file"
    return "$rc"
}

# Run one AT command through a qmanager_atd binary in qcmd (client) mode, with
# a hard timeout. The binary picks its mode from argv[0]: run under its own
# name it starts a second broker daemon (which would take over the socket), so
# it is always called through a temp symlink named qcmd. That works for the
# bundled binary and for whatever older build is already installed.
# Usage: run_atd_qcmd <seconds> <qmanager_atd path> <AT command>
run_atd_qcmd() {
    local seconds="$1"
    local bin="$2"
    local cmd="$3"
    local dir
    local rc=0

    # mktemp -d: a fresh root 0700 dir, never one another user planted (B4.1).
    dir=$(mktemp -d /tmp/qm_atd_qcmd.XXXXXX 2>/dev/null) || return 1
    if ! ln -s "$bin" "$dir/qcmd"; then
        rm -rf "$dir"
        return 1
    fi
    run_capture_timeout "$seconds" "$dir/qcmd" "$cmd" || rc=$?
    rm -rf "$dir"
    return "$rc"
}

pkg_binary() {
    case "$1" in
        ookla-speedtest)    echo "speedtest" ;;
        coreutils-timeout)  echo "timeout" ;;
        *) echo "$1" ;;
    esac
}

count_files() {
    find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
}

# --- Durable Flush -----------------------------------------------------------
# /usr, /www and /etc all live on the UBIFS /usrdata volume (overlay upper +
# /etc bind), whose dirty pages only reach flash after dirty_expire (30 s).
# An AP hang or power loss inside that window can leave freshly written files
# 0 bytes — and a rename alone is not durable: the rename can commit before
# the new file's data, so the file survives the crash but empty. 2026-10-19: a
# dev deploy cp'd 8 poller files, restarted the poller without sync, the AP
# hung ~30 s later and the power cycle left all 8 files 0 bytes. So: stage,
# flush, rename, and flush again before anything that can hang the device
# (daemon restarts, the reboot).

flush_storage() {
    _log_raw "sync: $1"
    sync 2>/dev/null || true
}

# --- Atomic File Install -----------------------------------------------------
# stage_file copies src to "$dst.qm_install.$$" with a size check, CRLF strip
# and chmod; commit_file renames that temp over dst. Callers flush_storage
# between the two so the staged bytes are on flash before the old file is
# replaced — a crash then leaves either the old or the new file, never a 0-byte
# one. install_file does all three for a single file; install_dir_flat stages a
# whole directory, flushes once, then commits.
#
# Each returns 0 on success, 1 on failure (caller decides whether to die).

stage_file() {
    local src="$1" dst="$2" mode="${3:-755}"

    if [ ! -f "$src" ]; then
        _log_raw "install_file: source missing: $src"
        return 1
    fi

    mkdir -p "$(dirname "$dst")" 2>/dev/null || true

    local tmp="$dst.qm_install.$$"
    local src_bytes
    local tmp_bytes

    if ! cp "$src" "$tmp" 2>>"$LOG_FILE"; then
        _log_raw "install_file: cp failed: $src -> $tmp"
        rm -f "$tmp"
        return 1
    fi

    # Integrity check: the copied bytes must equal the source exactly. A
    # truncated cp (interrupted transfer / ENOSPC) can leave a 0-byte or
    # partial file that still passes `sh -n` and execs as a silent no-op —
    # this shipped an empty qmanager_profile_apply once and broke profile
    # activation with start_failed. Must run BEFORE the CRLF strip, where tmp
    # is still byte-identical to src. wc -c is BusyBox-core (no stat/md5 dep);
    # tr -d ' ' normalizes the leading whitespace some wc builds emit.
    src_bytes=$(wc -c < "$src" 2>/dev/null | tr -d ' ')
    tmp_bytes=$(wc -c < "$tmp" 2>/dev/null | tr -d ' ')
    if [ "$src_bytes" != "$tmp_bytes" ]; then
        _log_raw "install_file: SIZE MISMATCH (truncated copy) $src (${src_bytes} B) -> $tmp (${tmp_bytes} B)"
        rm -f "$tmp"
        return 1
    fi

    # CRLF safety net for shell scripts. Build.sh should prevent CRLF in
    # the tarball but Windows-side editors and SMB shares can re-introduce
    # it. CRLF stripping must NEVER run on binary files — ELF binaries
    # contain 0x0D bytes throughout their machine code, and stripping them
    # corrupts the binary (manifests as "Segmentation fault" on first run).
    # Detect ELF via magic bytes (\x7fELF at offset 0) and skip the strip.
    if ! head -c 4 "$tmp" 2>/dev/null | grep -q ELF; then
        if grep -q "$(printf '\r')" "$tmp" 2>/dev/null; then
            if tr -d '\r' < "$tmp" > "$tmp.lf"; then
                mv "$tmp.lf" "$tmp"
                _log_raw "install_file: stripped CRLF from $(basename "$src")"
            else
                rm -f "$tmp.lf"
            fi
        fi
    else
        _log_raw "install_file: $(basename "$src") is ELF — skipping CRLF strip"
    fi

    chmod "$mode" "$tmp" 2>/dev/null || true

    return 0
}

commit_file() {
    local dst="$1"
    local tmp="$dst.qm_install.$$"

    # Atomic replacement. Requires caller to have stopped any running process
    # that has $dst open, otherwise this will fail with ETXTBSY.
    if ! mv "$tmp" "$dst" 2>>"$LOG_FILE"; then
        _log_raw "install_file: atomic rename failed: $tmp -> $dst"
        rm -f "$tmp"
        return 1
    fi

    return 0
}

install_file() {
    stage_file "$1" "$2" "$3" || return 1
    flush_storage "staged $(basename "$2")"
    commit_file "$2"
}

# Install every file in a flat source directory. Sets INSTALL_DIR_FLAT_COUNT
# to the number of files installed. Dies on any individual failure. Stages
# every file first, flushes once, then renames them all into place.
# Call it directly, never as x=$(install_dir_flat ...): inside a command
# substitution `die` only exits the subshell, its error line is captured
# instead of shown, and only `set -e` (off in if/||/&& contexts) would stop
# the install.
INSTALL_DIR_FLAT_COUNT=0
install_dir_flat() {
    local src="$1" dst="$2" mode="${3:-755}" count=0 fname

    INSTALL_DIR_FLAT_COUNT=0
    [ -d "$src" ] || die "install_dir_flat: missing source $src"
    mkdir -p "$dst" || die "Cannot create $dst"

    for f in "$src"/*; do
        [ -f "$f" ] || continue
        fname="$(basename "$f")"
        if ! stage_file "$f" "$dst/$fname" "$mode"; then
            rm -f "$dst"/*.qm_install.$$ 2>/dev/null
            die "Failed to install $fname to $dst"
        fi
    done

    flush_storage "staged $dst"

    for f in "$src"/*; do
        [ -f "$f" ] || continue
        fname="$(basename "$f")"
        if commit_file "$dst/$fname"; then
            count=$(( count + 1 ))
        else
            rm -f "$dst"/*.qm_install.$$ 2>/dev/null
            die "Failed to install $fname to $dst"
        fi
    done

    INSTALL_DIR_FLAT_COUNT=$count
    return 0
}

# Recursively install a directory tree (used for CGI which has subdirs).
# Builds a complete fresh copy in a staging dir, flushes it to flash, then
# swaps it in for a clean replacement. Applies 755 to all .sh files and 644 to
# everything else. The staging dir lives under /usr/lib (same overlay as /www,
# so the swap is a rename) because anything under /www/cgi-bin would be
# executable over HTTP while it exists.
install_tree() {
    local src="$1" dst="$2"
    local mismatch
    local live="$dst"
    local old="$TREE_STAGE_ROOT/old.$$"

    [ -d "$src" ] || { _log_raw "install_tree: missing source $src"; return 1; }

    # Leftovers from an interrupted earlier install are never needed.
    rm -rf "$TREE_STAGE_ROOT"
    mkdir -p "$TREE_STAGE_ROOT" "$(dirname "$live")"
    dst="$TREE_STAGE_ROOT/new.$$"
    mkdir -p "$dst"
    cp -r "$src"/. "$dst"/ || die "Failed to copy $src to $dst"

    # Integrity sweep: every source file must have a destination counterpart
    # of equal byte size. Same failure mode as install_file — a truncated
    # cp -r can silently deploy a 0-byte CGI script. Must run BEFORE the CRLF
    # strip, which legitimately changes dst sizes. The `find | while` body runs
    # in a SUBSHELL (pipe), so a `die` there would only exit the subshell and
    # let the install continue past a broken file — instead we record each
    # mismatch to a marker file and `die` in the current shell after the loop.
    mismatch="/tmp/qm_install_treechk.$$"
    rm -f "$mismatch"
    find "$src" -type f | while IFS= read -r sf; do
        rel=${sf#"$src"/}
        df="$dst/$rel"
        sb=$(wc -c < "$sf" 2>/dev/null | tr -d ' ')
        db=$(wc -c < "$df" 2>/dev/null | tr -d ' ')
        if [ "$sb" != "$db" ]; then
            printf '%s (src=%s dst=%s)\n' "$rel" "$sb" "$db" >> "$mismatch"
        fi
    done
    if [ -f "$mismatch" ]; then
        _log_raw "install_tree: truncated copies detected:"
        cat "$mismatch" >> "$LOG_FILE" 2>/dev/null || true
        rm -f "$mismatch"
        die "install_tree: $src -> $dst copy truncated (see $LOG_FILE)"
    fi

    # CRLF strip across the whole tree
    find "$dst" -type f -name "*.sh" | while IFS= read -r f; do
        if grep -q "$(printf '\r')" "$f" 2>/dev/null; then
            tr -d '\r' < "$f" > "$f.lf" && mv "$f.lf" "$f"
        fi
    done

    find "$dst" -type f -name "*.sh" -exec chmod 755 {} \;
    find "$dst" -type f ! -name "*.sh" -exec chmod 644 {} \;

    flush_storage "staged $live"

    if [ -d "$live" ]; then
        mv "$live" "$old" || die "install_tree: cannot move aside $live"
    fi
    if ! mv "$dst" "$live"; then
        [ -d "$old" ] && mv "$old" "$live"
        die "install_tree: cannot move $dst into $live"
    fi
    rm -rf "$TREE_STAGE_ROOT"

    return 0
}

# --- Pre-flight --------------------------------------------------------------

detect_modem_firmware() {
    local atd=""
    local raw=""
    local detected=""
    local cache

    # Prefer the installed broker binary, fall back to the bundled one. Either
    # runs as the qcmd client: through the running broker, or in-process.
    if [ -x "$BIN_DIR/qmanager_atd" ]; then
        atd="$BIN_DIR/qmanager_atd"
    elif [ -f "$SRC_DEPS/qmanager_atd" ]; then
        chmod 755 "$SRC_DEPS/qmanager_atd" 2>/dev/null || true
        [ -x "$SRC_DEPS/qmanager_atd" ] && atd="$SRC_DEPS/qmanager_atd"
    fi

    if [ -n "$atd" ]; then
        raw=$(run_atd_qcmd 8 "$atd" 'ATI' 2>/dev/null || true)

        detected=$(printf '%s\n' "$raw" \
            | tr -d '\r' \
            | sed -n 's/^VERSION:[[:space:]]*//p' \
            | head -n1)

        if [ -z "$detected" ]; then
            detected=$(printf '%s\n' "$raw" | tr -d '\r' | grep -E 'RM[0-9]{3,}' | head -n1)
        fi

        if [ -z "$detected" ]; then
            raw=$(run_atd_qcmd 8 "$atd" 'AT+GMR' 2>/dev/null || true)
            detected=$(printf '%s\n' "$raw" | tr -d '\r' | grep -E 'RM[0-9]{3,}' | head -n1)
        fi
    fi

    # Cache fallback: on upgrade, the running (older) broker may refuse a
    # request from a newer client, or /dev/smd11 may be temporarily busy, but
    # the poller's cache file already contains the firmware string.
    if [ -z "$detected" ]; then
        for cache in /tmp/qmanager_status.json /etc/qmanager/status.json; do
            [ -f "$cache" ] || continue
            detected=$(tr -d '\r\n' < "$cache" \
                | sed -n 's/.*"device"[[:space:]]*:[[:space:]]*{[^}]*"firmware"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            [ -n "$detected" ] && break
        done
    fi

    [ -n "$detected" ] || return 1
    printf '%s' "$detected"
    return 0
}

preflight() {
    step "Pre-flight checks"

    [ "$(id -u)" -eq 0 ] || die "This script must be run as root"

    if [ -f /etc/openwrt_release ]; then
        local distro
        distro=$(. /etc/openwrt_release && echo "$DISTRIB_DESCRIPTION")
        info "OpenWRT detected: $distro"
    else
        warn "Cannot detect OpenWRT — proceeding anyway"
    fi

    # Source dir sanity
    [ "$DO_FRONTEND" = "1" ] && [ ! -d "$SRC_FRONTEND" ] \
        && die "Frontend source not found: $SRC_FRONTEND"
    [ "$DO_BACKEND" = "1" ]  && [ ! -d "$SRC_SCRIPTS" ] \
        && die "Backend source not found: $SRC_SCRIPTS"
    [ "$DO_BACKEND" = "1" ]  && [ ! -d "$SRC_DEPS" ] \
        && die "Bundled deps not found: $SRC_DEPS"

    # Modem firmware detection
    if [ "$DO_FORCE" = "1" ]; then
        warn "Skipping modem firmware check (--force)"
        info "Pre-flight checks passed"
        return 0
    fi

    local fw
    fw=$(detect_modem_firmware || true)

    if [ -z "$fw" ]; then
        warn "Could not detect modem firmware (tried ATI/AT+GMR and cache)"
        warn "This usually means /dev/smd11 is busy or the modem is not responsive"
        if [ -t 0 ]; then
            printf "\n    Continue installation anyway? [y/N] "
            read -r answer
            case "$answer" in
                y|Y|yes|YES)
                    warn "Proceeding without firmware verification"
                    ;;
                *)
                    die "Installation aborted by user"
                    ;;
            esac
        else
            die "Firmware detection failed and shell is non-interactive. Use --force to override."
        fi
        info "Pre-flight checks passed"
        return 0
    fi

    local fw_norm
    fw_norm=$(printf '%s' "$fw" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9')
    if ! printf '%s' "$fw_norm" | grep -q "$REQUIRED_FIRMWARE"; then
        die "Unsupported modem firmware: $fw (expected token: $REQUIRED_FIRMWARE)"
    fi

    info "Modem firmware: $fw"
    info "Signature check passed ($REQUIRED_FIRMWARE)"
    info "Pre-flight checks passed"
}

# --- Web Port ----------------------------------------------------------------

# Ask, once, which ports QManager should be served on. Only when the shell is
# interactive (the OTA updater runs detached with no tty, so it never stops
# here) and only while quecmanager.web is unset (an existing choice is
# preserved). Defaults are the ports uhttpd uses now (80 / 443 on stock).
# Sets WEB_HTTP_PORT / WEB_HTTPS_PORT; seed_uci_defaults writes them.
WEB_HTTP_PORT=""
WEB_HTTPS_PORT=""

prompt_web_port() {
    local lib="$SRC_SCRIPTS/usr/lib/qmanager/web_port.sh"
    [ "$CONFIGURE" = "1" ] && lib="$LIB_DIR/web_port.sh"
    [ -f "$lib" ] || return 0
    . "$lib"

    WEB_HTTP_PORT=$(wp_conf_http)
    WEB_HTTPS_PORT=$(wp_conf_https)

    # opkg can hand its maintainer scripts the terminal; never prompt there.
    [ -t 0 ] && [ "$IN_OPKG" = "0" ] || return 0
    uci -q get quecmanager.web >/dev/null 2>&1 && return 0

    printf "\n  QManager is served on HTTP %s and HTTPS %s (LuCI moves with it).\n" \
        "$WEB_HTTP_PORT" "$WEB_HTTPS_PORT"
    printf "  Use different ports? [y/N] "
    local answer=""
    read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES) ;;
        *) return 0 ;;
    esac

    local tries=0
    local h=""
    local s=""
    local err=""
    while [ "$tries" -lt 3 ]; do
        printf "    HTTP port [%s]: " "$WEB_HTTP_PORT"
        read -r h || h=""
        [ -n "$h" ] || h="$WEB_HTTP_PORT"
        printf "    HTTPS port [%s]: " "$WEB_HTTPS_PORT"
        read -r s || s=""
        [ -n "$s" ] || s="$WEB_HTTPS_PORT"
        err=$(wp_validate "$h" "$s") || true
        if [ -z "$err" ]; then
            WEB_HTTP_PORT="$h"
            WEB_HTTPS_PORT="$s"
            info "QManager will use HTTP $h and HTTPS $s"
            return 0
        fi
        case "$err" in
            ports_equal)   warn "HTTP and HTTPS need different ports" ;;
            port_in_use:*) warn "Port ${err#port_in_use:} is already used by another service" ;;
            *)             warn "Ports must be whole numbers from 1 to 65535" ;;
        esac
        tries=$(( tries + 1 ))
    done
    warn "Keeping HTTP $WEB_HTTP_PORT and HTTPS $WEB_HTTPS_PORT (change later in System Settings or with qmanager_web_port)"
    return 0
}

# Persist the chosen ports and point uhttpd at them. A full install reboots
# right after, which brings uhttpd up on the new ports; without a reboot,
# wp_apply restarts uhttpd now (and rolls back if it cannot bind).
seed_web_port() {
    command -v wp_save_conf >/dev/null 2>&1 || return 0
    wp_port_valid "$WEB_HTTP_PORT" && wp_port_valid "$WEB_HTTPS_PORT" || return 0

    if uci -q get quecmanager.web >/dev/null 2>&1; then
        info "quecmanager.web already set — preserving user choice ($(wp_conf_http) / $(wp_conf_https))"
        return 0
    fi
    wp_save_conf "$WEB_HTTP_PORT" "$WEB_HTTPS_PORT" || { warn "Could not save the web port"; return 0; }
    info "Seeded quecmanager.web (HTTP $WEB_HTTP_PORT, HTTPS $WEB_HTTPS_PORT)"

    if [ "$WEB_HTTP_PORT" = "$(wp_uhttpd_http)" ] && [ "$WEB_HTTPS_PORT" = "$(wp_uhttpd_https)" ]; then
        return 0
    fi
    if [ "$DO_REBOOT" = "1" ]; then
        wp_write_uhttpd "$WEB_HTTP_PORT" "$WEB_HTTPS_PORT"
        info "Web server moves to HTTP $WEB_HTTP_PORT / HTTPS $WEB_HTTPS_PORT after the reboot"
    else
        local r
        r=$(wp_apply) || true
        case "$r" in
            applied*) info "Web server now on HTTP $WEB_HTTP_PORT / HTTPS $WEB_HTTPS_PORT" ;;
            *)        warn "Could not move the web server ($r); it stays on its current ports" ;;
        esac
    fi
}

# --- Version Markers ---------------------------------------------------------

mark_version_pending() {
    # Writing the pending marker BEFORE touching the filesystem means that a
    # partial install leaves VERSION unchanged (old value) and VERSION.pending
    # present, which is a clear signal of an aborted upgrade for debugging.
    mkdir -p "$CONF_DIR"
    printf '%s' "$VERSION" > "$VERSION_PENDING"
    _log_raw "Marked pending version: $VERSION"
}

finalize_version() {
    if [ -f "$VERSION_PENDING" ]; then
        mv "$VERSION_PENDING" "$VERSION_FILE" 2>/dev/null \
            || printf '%s' "$VERSION" > "$VERSION_FILE"
    else
        printf '%s' "$VERSION" > "$VERSION_FILE"
    fi
    _log_raw "Finalized version file: $VERSION_FILE = $VERSION"
}

# --- Package Management ------------------------------------------------------

remove_conflicts() {
    step "Removing conflicting packages"

    conflict_pkg_installed() {
        local pkg="$1"
        local installed

        installed=$(opkg list-installed 2>>"$LOG_FILE") \
            || die "Failed to query installed packages via opkg"

        printf '%s\n' "$installed" | awk '{print $1}' | grep -qx "$pkg"
    }

    local any=0
    local failed=0
    for pkg in $CONFLICT_PACKAGES; do
        if conflict_pkg_installed "$pkg"; then
            any=1
            if opkg remove "$pkg" >>"$LOG_FILE" 2>&1; then
                info "Removed: $pkg"
            else
                warn "Could not remove $pkg normally, retrying with forced dependency removal"
                if opkg remove --force-removal-of-dependent-packages "$pkg" >>"$LOG_FILE" 2>&1; then
                    info "Removed with force-removal-of-dependent-packages: $pkg"
                elif opkg remove --force-depends "$pkg" >>"$LOG_FILE" 2>&1; then
                    info "Removed with force-depends: $pkg"
                else
                    warn "Could not remove $pkg even with force flags"
                    failed=1
                fi
            fi

            if conflict_pkg_installed "$pkg"; then
                warn "$pkg is still installed after removal attempts"
                failed=1
            fi
        fi
    done
    [ "$any" = "0" ] && info "No conflicting packages found"

    if [ "$failed" != "0" ]; then
        die "Conflicting packages must be removed before install can continue. Remove manually with: opkg remove sms-tool socat-at-bridge socat"
    fi

    return 0
}

# Retire the WebSocket live-traffic bandwidth monitor (websocat + the
# bridge_traffic_monitor_rm551 binary, removed in this version). Runs
# unconditionally from main() — Software Update invokes install.sh with
# --skip-packages, so this must not live inside install_packages. The service
# is stopped + disabled through its init.d first because procd respawns both
# instances if they are only killall'd. Idempotent; silent on fresh installs.
retire_bandwidth_monitor() {
    local retired=0

    if [ -f "$INITD_DIR/qmanager_bandwidth" ]; then
        "$INITD_DIR/qmanager_bandwidth" stop >/dev/null 2>&1 || true
        "$INITD_DIR/qmanager_bandwidth" disable >/dev/null 2>&1 || true
        rm -f "$INITD_DIR/qmanager_bandwidth"
        retired=1
    fi
    rm -f /etc/rc.d/*qmanager_bandwidth* 2>/dev/null || true

    killall websocat >/dev/null 2>&1 || true
    killall bridge_traffic_monitor_rm551 >/dev/null 2>&1 || true

    if uci -q delete quecmanager.bridge_monitor 2>/dev/null; then
        uci -q commit quecmanager 2>/dev/null || true
        retired=1
    fi

    if [ -f "$BIN_DIR/bridge_traffic_monitor_rm551" ] || [ -f "$BIN_DIR/qmanager_bandwidth_genconf" ]; then
        retired=1
    fi
    rm -f "$BIN_DIR/qmanager_bandwidth_genconf" "$BIN_DIR"/bridge_traffic_monitor_* 2>/dev/null || true
    rm -f /etc/quecmanager/settings/bridge_traffic_monitor.conf \
          /tmp/quecmanager/bridge_traffic_monitor \
          /tmp/quecmanager/bridge_traffic_monitor.pid 2>/dev/null || true
    rm -rf /etc/qmanager/bandwidth_certs 2>/dev/null || true

    # Inside opkg the package's Conflicts/Replaces handle websocat instead.
    if [ "$IN_OPKG" = "0" ] && opkg list-installed 2>/dev/null | awk '{print $1}' | grep -qx websocat; then
        if opkg remove websocat >>"$LOG_FILE" 2>&1; then
            info "Removed package: websocat"
        else
            warn "Could not remove websocat package (harmless; nothing uses it now)"
        fi
    fi

    [ "$retired" = "1" ] && info "Retired legacy bandwidth monitor (qmanager_bandwidth)"
    return 0
}

# Retire Low Power Mode (cron entries, boot-check init.d, daemons, UCI keys).
# Runs unconditionally from main(), before stop_services, so the old broker
# and qcmd link are still live for the CFUN restore. If a box is upgraded
# inside a low-power window the radio is off (CFUN=0): bring it back with
# AT+CFUN=1 (never 1,1) and drop the flag + watchcat lock that window set.
# The watchcat lock is shared with the watchdog, so it is only removed here.
# Idempotent; silent on fresh installs.
retire_low_power() {
    local retired=0
    local cron_now=""
    local cron_clean=""

    if [ -f /tmp/qmanager_low_power_active ]; then
        if command -v qcmd >/dev/null 2>&1; then
            run_capture_timeout 10 qcmd 'AT+CFUN=1' >/dev/null 2>&1 || true
        fi
        rm -f /tmp/qmanager_low_power_active /tmp/qmanager_watchcat.lock
        retired=1
    fi

    if [ -f "$INITD_DIR/qmanager_low_power_check" ]; then
        "$INITD_DIR/qmanager_low_power_check" disable >/dev/null 2>&1 || true
        rm -f "$INITD_DIR/qmanager_low_power_check"
        retired=1
    fi
    rm -f /etc/rc.d/*qmanager_low_power* 2>/dev/null || true

    if [ -f "$BIN_DIR/qmanager_low_power" ] || [ -f "$BIN_DIR/qmanager_low_power_check" ]; then
        retired=1
    fi
    rm -f "$BIN_DIR/qmanager_low_power" "$BIN_DIR/qmanager_low_power_check"

    cron_now=$(crontab -l 2>/dev/null || true)
    if printf '%s\n' "$cron_now" | grep -q "qmanager_low_power"; then
        cron_clean=$(printf '%s\n' "$cron_now" \
            | grep -v "qmanager_low_power" \
            | grep -v "^# QManager Low Power Mode")
        if [ -n "$cron_clean" ]; then
            printf '%s\n' "$cron_clean" | crontab - 2>/dev/null || true
        else
            echo "" | crontab - 2>/dev/null || true
        fi
        retired=1
    fi

    local key
    local deleted=0
    for key in low_power_enabled low_power_start low_power_end low_power_days; do
        if uci -q delete "quecmanager.settings.$key" 2>/dev/null; then
            deleted=1
        fi
    done
    if [ "$deleted" = "1" ]; then
        uci -q commit quecmanager 2>/dev/null || true
        retired=1
    fi

    [ "$retired" = "1" ] && info "Retired Low Power Mode"
    return 0
}

install_packages() {
    step "Installing required packages"

    if run_with_spinner "Updating package lists" opkg update; then
        info "Package lists updated"
    else
        warn "opkg update failed — will try installing from cache"
    fi

    for pkg in $REQUIRED_PACKAGES; do
        if command -v "$(pkg_binary "$pkg")" >/dev/null 2>&1; then
            info "$pkg already installed"
        elif run_with_spinner "Installing $pkg" opkg install "$pkg"; then
            info "$pkg installed"
        else
            die "Failed to install required package: $pkg"
        fi
    done

    printf "\n"
    info "Optional packages available:"
    for pkg in $OPTIONAL_PACKAGES; do
        case "$pkg" in
            msmtp)           printf "    %-18s — email alerts\n" "$pkg" ;;
            ethtool)         printf "    %-18s — ethernet link speed control\n" "$pkg" ;;
            ookla-speedtest) printf "    %-18s — speed test\n" "$pkg" ;;
            *)               printf "    %-18s\n" "$pkg" ;;
        esac
    done

    local answer=""
    if [ -t 0 ]; then
        printf "\n  Install optional packages? [Y/n] "
        read -r answer || answer=""
    else
        info "Non-interactive shell — installing optional packages by default"
    fi

    case "$answer" in
        n|N|no|NO)
            info "Skipping optional packages"
            ;;
        *)
            for pkg in $OPTIONAL_PACKAGES; do
                if command -v "$(pkg_binary "$pkg")" >/dev/null 2>&1; then
                    info "$pkg already installed"
                elif run_with_spinner "Installing $pkg" opkg install "$pkg"; then
                    info "$pkg installed"
                else
                    warn "$pkg not available — feature will be disabled"
                fi
            done
            ;;
    esac
}

# --- Service Management (filesystem-driven) ----------------------------------

# Stop all QManager services. Order matters here:
#
#   1. Touch the watchcat lock file FIRST. Watchcat checks this at the top
#      of its main loop and enters LOCKED state, skipping all escalation
#      tiers. Without this guard, watchcat would observe the disruption
#      caused by stopping the poller / DPI / etc, fail its connectivity
#      checks, and could escalate to Tier 4 (system reboot) mid-install.
#
#   2. Hard-kill watchcat (SIGKILL) BEFORE anything else. SIGKILL bypasses
#      the trap handler so even if watchcat was mid-execute_tier4 it can't
#      spawn the detached `( sleep 1 && reboot ) &` subshell.
#
#   3. Kill ALL other qmanager_* daemons (SIGTERM, brief drain, then
#      SIGKILL stragglers) BEFORE calling init.d stop. This is the key
#      fix: if procd's stop_service has to wait for a daemon that's
#      mid-AT-command, it can stall for tens of seconds per service. With
#      11 init.d scripts in series, the cumulative stall starves the
#      kernel hardware watchdog and the device reboots spontaneously
#      ~1-2 minutes into the install.
#
#   4. THEN call init.d stop on every qmanager* script. With daemons
#      already dead, procd's stop_service returns immediately — it just
#      runs the cleanup hooks (rm -f state files).
#
# Before any of that, snapshot_running_services records which services were
# running so start_services can bring them back (no-reboot installs).
snapshot_running_services() {
    RUNNING_BEFORE_STOP=""
    [ -d "$INITD_DIR" ] || return 0

    for svc in "$INITD_DIR"/qmanager*; do
        [ -x "$svc" ] || continue
        local name
        name="$(basename "$svc")"

        if [ "$name" = "qmanager_tower_failover" ]; then
            # Non-procd daemon tracked by a pid file
            local pid
            pid=$(cat /tmp/qmanager_tower_failover.pid 2>/dev/null | tr -d ' \n\r')
            case "$pid" in
                ''|*[!0-9]*) continue ;;
            esac
            kill -0 "$pid" 2>/dev/null || continue
        else
            # Only procd scripts have a working "running" command; on a
            # non-procd rc.common script it prints usage and returns 0.
            grep -q '^USE_PROCD=1' "$svc" 2>/dev/null || continue
            "$svc" running >/dev/null 2>&1 || continue
        fi

        RUNNING_BEFORE_STOP="$RUNNING_BEFORE_STOP $name"
    done

    if [ -n "$RUNNING_BEFORE_STOP" ]; then
        info "Running before stop:$RUNNING_BEFORE_STOP"
    fi
}

stop_services() {
    step "Stopping QManager services"

    snapshot_running_services

    # Step 1: Pause watchcat for the entire install window.
    # Note: the lock file mechanism was added in v0.1.15 — any pre-v0.1.15
    # watchcat binary on disk will ignore this file. That's why step 2 uses
    # init.d stop (to disable procd respawn) instead of relying on the lock.
    touch "$WATCHCAT_LOCK" 2>/dev/null || true
    info "Watchcat locked for install window"

    # Step 2: Stop watchcat FIRST via init.d so procd marks it stopped and
    # won't respawn it mid-install. Critical on upgrade paths where the
    # currently-running watchcat may be an older version that doesn't honour
    # the maintenance lock file — a respawned old-version instance can
    # observe the install disruption, fail its connectivity checks, and
    # escalate to Tier 4 (system reboot) before we've finished installing.
    if [ -x "$INITD_DIR/qmanager_watchcat" ]; then
        "$INITD_DIR/qmanager_watchcat" stop 2>>"$LOG_FILE" || true
    fi
    killall -9 qmanager_watchcat 2>/dev/null || true
    # Re-assert the lock in case an older init.d stop_service() hook
    # (pre-v0.1.15) removed /tmp/qmanager_watchcat.lock on the way out.
    touch "$WATCHCAT_LOCK" 2>/dev/null || true

    # Step 3: Stop every other qmanager* init.d service BEFORE killall'ing
    # daemons. procd-managed services (poller, ping, dpi, tower_failover,
    # bandwidth, etc.) would otherwise be respawned by procd after we kill
    # them, opening the same race window as watchcat. Running init.d stop
    # first tells procd the service should be stopped — it won't respawn.
    if [ -d "$INITD_DIR" ]; then
        for svc in "$INITD_DIR"/qmanager*; do
            [ -x "$svc" ] || continue
            # Watchcat was already stopped in step 2
            [ "$(basename "$svc")" = "qmanager_watchcat" ] && continue
            "$svc" stop 2>>"$LOG_FILE" || true
        done
        info "Stopped all init.d services"
    fi

    # Step 4: SIGTERM any qmanager_* daemons that slipped past init.d stop
    # (e.g. non-procd one-shot scripts, or processes that ignored SIGTERM).
    if [ -d "$BIN_DIR" ]; then
        for f in "$BIN_DIR"/qmanager_*; do
            [ -f "$f" ] || continue
            local pname
            pname="$(basename "$f")"
            # Never kill updater workers during OTA installs. If qmanager_update
            # (or qmanager_auto_update -> qmanager_update chain) is terminated
            # here, OTA status can be left stuck at "installing" with no reboot.
            case "$pname" in
                qmanager_update|qmanager_auto_update) continue ;;
            esac
            killall "$pname" 2>/dev/null || true
        done
    fi
    for p in bridge_traffic_monitor_rm551 websocat nfqws; do
        killall "$p" 2>/dev/null || true
    done

    # Brief drain so daemons can flush state files via their EXIT traps
    sleep 1

    # Step 5: SIGKILL stragglers — anything still alive after the drain
    if [ -d "$BIN_DIR" ]; then
        for f in "$BIN_DIR"/qmanager_*; do
            [ -f "$f" ] || continue
            local pname
            pname="$(basename "$f")"
            case "$pname" in
                qmanager_update|qmanager_auto_update) continue ;;
            esac
            killall -9 "$pname" 2>/dev/null || true
        done
    fi
    for p in bridge_traffic_monitor_rm551 websocat nfqws; do
        killall -9 "$p" 2>/dev/null || true
    done

    info "All services stopped"
}

seed_uci_defaults() {
    step "Seeding UCI defaults"

    # Tailscale network fixes (fw4 zone + pref-1990 ip rule) — ON by default.
    # The Tailscale page toggles it; qmanager_tailscale_net re-asserts it at
    # boot. Preserve any existing user value (migrate_tailscale_net already
    # mapped the retired tailscale_workarounds key onto this section).
    if ! uci -q get quecmanager.tailscale_net >/dev/null 2>&1; then
        uci set quecmanager.tailscale_net=tailscale_net
    fi
    if ! uci -q get quecmanager.tailscale_net.enabled >/dev/null 2>&1; then
        uci set quecmanager.tailscale_net.enabled=1
        info "Seeded quecmanager.tailscale_net.enabled=1 (on by default)"
    else
        info "quecmanager.tailscale_net.enabled already set — preserving user choice"
    fi

    # Connection Quality — ping profile (drives qmanager_ping interval +
    # fail/recover thresholds and the 2 HTTP probe targets). The profile NAME
    # is the only knob persisted; the daemon holds the profile->params table.
    # Seed concrete, user-editable defaults. NOTE: quality_thresholds is
    # deliberately NOT seeded — its absence is the "default" signal that drives
    # the frontend isDefault hint and the tolerant/tolerant fallback in the
    # poller + quality_thresholds.sh CGI.
    if ! uci -q get quecmanager.ping_profile >/dev/null 2>&1; then
        uci set quecmanager.ping_profile=ping_profile
    fi
    if ! uci -q get quecmanager.ping_profile.profile >/dev/null 2>&1; then
        uci set quecmanager.ping_profile.profile='relaxed'
        info "Seeded quecmanager.ping_profile.profile=relaxed"
    else
        info "quecmanager.ping_profile.profile already set — preserving user choice"
    fi
    if ! uci -q get quecmanager.ping_profile.target_ipv4 >/dev/null 2>&1; then
        uci set quecmanager.ping_profile.target_ipv4='1.1.1.1'
        info "Seeded quecmanager.ping_profile.target_ipv4=1.1.1.1"
    else
        info "quecmanager.ping_profile.target_ipv4 already set — preserving user choice"
    fi
    if ! uci -q get quecmanager.ping_profile.target_ipv6 >/dev/null 2>&1; then
        uci set quecmanager.ping_profile.target_ipv6='2606:4700:4700::1111'
        info "Seeded quecmanager.ping_profile.target_ipv6=2606:4700:4700::1111"
    else
        info "quecmanager.ping_profile.target_ipv6 already set — preserving user choice"
    fi

    # Upgrade migration — the ping probe is now ICMP (BusyBox ping), not curl/HTTP.
    # The legacy target_1/target_2 keys held HTTP(S) URLs and are useless as ICMP
    # targets, so delete them outright if present. The new target_ipv4/target_ipv6
    # keys are seeded above. The profile NAME is sacred and never touched here.
    # uci commit happens once at the end of this function; touch the reload flag
    # so a running daemon re-reads the new ICMP targets.
    _ping_migrated=0
    if uci -q get quecmanager.ping_profile.target_1 >/dev/null 2>&1; then
        uci -q delete quecmanager.ping_profile.target_1
        info "Removed obsolete quecmanager.ping_profile.target_1 (HTTP probe retired for ICMP)"
        _ping_migrated=1
    fi
    if uci -q get quecmanager.ping_profile.target_2 >/dev/null 2>&1; then
        uci -q delete quecmanager.ping_profile.target_2
        info "Removed obsolete quecmanager.ping_profile.target_2 (HTTP probe retired for ICMP)"
        _ping_migrated=1
    fi
    if [ "$_ping_migrated" = "1" ]; then
        touch /tmp/qmanager_ping_reload
        info "Dropped /tmp/qmanager_ping_reload — running ping daemon will pick up ICMP targets"
    fi

    # Connection Watchdog (watchcat) — every key is seeded here, so a fresh
    # install has the full section before the watchdog.sh CGI is ever opened
    # (ensure_watchcat_config there only covers a section that is missing
    # entirely). Idempotent + preserve-user-choice, same shape as the blocks
    # above. fail_threshold is seeded/migrated in the block further down.
    # Defaults match wd_config.sh and the CGI: off, 10s check, 60s cooldown,
    # tiers 1/2/4 on and Tier 3 off, 3 reboots/hour, quality off, consecutive 5.
    # NOTE: latency_ceiling_ms / loss_ceiling_pct are RETIRED — the watchdog now
    # reads the SHARED quecmanager.quality_thresholds.* (resolved with a `custom`
    # option). The migration block below moves any existing watchcat ceilings
    # into the shared custom thresholds. Do NOT re-seed the retired keys here.
    if ! uci -q get quecmanager.watchcat >/dev/null 2>&1; then
        uci set quecmanager.watchcat=watchcat
    fi
    for _wc_kv in enabled=0 check_interval=10 cooldown=60 \
                  tier1_enabled=1 tier2_enabled=1 tier3_enabled=0 tier4_enabled=1 \
                  max_reboots_per_hour=3; do
        _wc_k="${_wc_kv%%=*}"
        _wc_v="${_wc_kv#*=}"
        if ! uci -q get "quecmanager.watchcat.$_wc_k" >/dev/null 2>&1; then
            uci set "quecmanager.watchcat.$_wc_k=$_wc_v"
            info "Seeded quecmanager.watchcat.$_wc_k=$_wc_v"
        fi
    done
    if ! uci -q get quecmanager.watchcat.quality_enabled >/dev/null 2>&1; then
        uci set quecmanager.watchcat.quality_enabled=0
        info "Seeded quecmanager.watchcat.quality_enabled=0 (off by default)"
    else
        info "quecmanager.watchcat.quality_enabled already set — preserving user choice"
    fi
    if ! uci -q get quecmanager.watchcat.quality_consecutive >/dev/null 2>&1; then
        uci set quecmanager.watchcat.quality_consecutive=5
        info "Seeded quecmanager.watchcat.quality_consecutive=5"
    else
        info "quecmanager.watchcat.quality_consecutive already set — preserving user choice"
    fi
    if ! uci -q get quecmanager.watchcat.ssr_aware >/dev/null 2>&1; then
        uci set quecmanager.watchcat.ssr_aware=1
        info "Seeded quecmanager.watchcat.ssr_aware=1 (SSR-aware hold on by default)"
    else
        info "quecmanager.watchcat.ssr_aware already set — preserving user choice"
    fi
    if ! uci -q get quecmanager.watchcat.ssr_grace >/dev/null 2>&1; then
        uci set quecmanager.watchcat.ssr_grace=45
        info "Seeded quecmanager.watchcat.ssr_grace=45"
    else
        info "quecmanager.watchcat.ssr_grace already set — preserving user choice"
    fi
    if ! uci -q get quecmanager.watchcat.primary_recheck_enabled >/dev/null 2>&1; then
        uci set quecmanager.watchcat.primary_recheck_enabled=0
        info "Seeded quecmanager.watchcat.primary_recheck_enabled=0 (auto-failback off by default)"
    else
        info "quecmanager.watchcat.primary_recheck_enabled already set — preserving user choice"
    fi
    if ! uci -q get quecmanager.watchcat.primary_recheck_interval >/dev/null 2>&1; then
        uci set quecmanager.watchcat.primary_recheck_interval=30
        info "Seeded quecmanager.watchcat.primary_recheck_interval=30"
    else
        info "quecmanager.watchcat.primary_recheck_interval already set — preserving user choice"
    fi

    # ---------------------------------------------------------------------------
    # Watchdog/Quality unification migration (idempotent, exact-match guarded)
    # ---------------------------------------------------------------------------
    # Three coordinated schema changes; each step is a no-op on re-run.
    _wq_migrated=0

    # (1) max_failures -> fail_threshold. The watchdog's recovery trigger is now
    #     consecutive failed PROBES (raw ping streak_fail), not watchcat's own
    #     loop cycles. Copy the old value across once and delete the old key. If
    #     neither key exists (fresh install), seed fail_threshold=5.
    if ! uci -q get quecmanager.watchcat.fail_threshold >/dev/null 2>&1; then
        _old_max_fail=$(uci -q get quecmanager.watchcat.max_failures 2>/dev/null) || true
        if [ -n "$_old_max_fail" ]; then
            uci set quecmanager.watchcat.fail_threshold="$_old_max_fail"
            uci -q delete quecmanager.watchcat.max_failures 2>/dev/null
            info "Migrated watchcat.max_failures=$_old_max_fail -> watchcat.fail_threshold (deleted old key)"
            _wq_migrated=1
        else
            uci set quecmanager.watchcat.fail_threshold=5
            info "Seeded quecmanager.watchcat.fail_threshold=5"
            _wq_migrated=1
        fi
    else
        # fail_threshold already present — still drop a leftover max_failures.
        if uci -q get quecmanager.watchcat.max_failures >/dev/null 2>&1; then
            uci -q delete quecmanager.watchcat.max_failures 2>/dev/null
            info "Removed retired quecmanager.watchcat.max_failures (fail_threshold already set)"
            _wq_migrated=1
        else
            info "quecmanager.watchcat.fail_threshold already set — preserving user choice"
        fi
    fi

    # (2) Retire watchcat ceilings -> shared custom thresholds. DECISION: keep the
    #     WATCHDOG-side values. Only runs while a ceiling key still exists, so it
    #     fires exactly once (the delete makes re-runs no-ops). We overwrite the
    #     shared keys to `custom` here because the user's explicit watchdog
    #     ceiling is the authoritative degraded threshold post-unification.
    _old_lat_ceiling=$(uci -q get quecmanager.watchcat.latency_ceiling_ms 2>/dev/null) || true
    _old_loss_ceiling=$(uci -q get quecmanager.watchcat.loss_ceiling_pct 2>/dev/null) || true
    if [ -n "$_old_lat_ceiling" ] || [ -n "$_old_loss_ceiling" ]; then
        if ! uci -q get quecmanager.quality_thresholds >/dev/null 2>&1; then
            uci set quecmanager.quality_thresholds=quality_thresholds
        fi
        # Default device ceilings were 800ms / 20%; fall back to those if only one
        # ceiling key happened to exist.
        uci set quecmanager.quality_thresholds.latency_preset=custom
        uci set quecmanager.quality_thresholds.latency_custom_ms="${_old_lat_ceiling:-800}"
        uci set quecmanager.quality_thresholds.loss_preset=custom
        uci set quecmanager.quality_thresholds.loss_custom_pct="${_old_loss_ceiling:-20}"
        uci -q delete quecmanager.watchcat.latency_ceiling_ms 2>/dev/null
        uci -q delete quecmanager.watchcat.loss_ceiling_pct 2>/dev/null
        info "Migrated watchcat ceilings -> quality_thresholds custom (${_old_lat_ceiling:-800}ms / ${_old_loss_ceiling:-20}%); deleted retired keys"
        _wq_migrated=1
    fi
    # (3) If no ceilings existed, quality_thresholds is intentionally left ABSENT
    #     to preserve the never-seeded isDefault semantics — nothing to do.

    # Pick up the changes on the running daemons without an init restart.
    if [ "$_wq_migrated" = "1" ]; then
        touch /tmp/qmanager_ping_reload /tmp/qmanager_quality_reload
        info "Dropped /tmp/qmanager_ping_reload + /tmp/qmanager_quality_reload — running daemons will re-read"
    fi

    # SMS Forwarding — opt-in inbound-SMS relay daemon (qmanager_sms_forward,
    # gated via UCI_GATED_SERVICES so install never force-enables it). Seed the
    # section + concrete defaults so a fresh install has a stable shape. Disabled
    # by default; empty target. Idempotent + preserve-user-choice across upgrade.
    if ! uci -q get quecmanager.sms_forwarding >/dev/null 2>&1; then
        uci set quecmanager.sms_forwarding=sms_forwarding
    fi
    if ! uci -q get quecmanager.sms_forwarding.enabled >/dev/null 2>&1; then
        uci set quecmanager.sms_forwarding.enabled='0'
        info "Seeded quecmanager.sms_forwarding.enabled=0 (off by default)"
    else
        info "quecmanager.sms_forwarding.enabled already set — preserving user choice"
    fi
    if ! uci -q get quecmanager.sms_forwarding.target_phone >/dev/null 2>&1; then
        uci set quecmanager.sms_forwarding.target_phone=''
        info "Seeded quecmanager.sms_forwarding.target_phone=''"
    else
        info "quecmanager.sms_forwarding.target_phone already set — preserving user choice"
    fi

    # Call Forwarding (removed) — drop the stale section on upgrade from a build
    # that seeded quecmanager.call_forwarding. Harmless no-op on fresh installs.
    if uci -q get quecmanager.call_forwarding >/dev/null 2>&1; then
        uci -q delete quecmanager.call_forwarding 2>/dev/null
        info "Removed retired quecmanager.call_forwarding section"
    fi

    # AT engine switch (removed) — the broker is the only engine now. The
    # quecmanager.at section held nothing but the old engine choice, so drop it
    # whole on upgrade. Harmless no-op on fresh installs.
    if uci -q get quecmanager.at >/dev/null 2>&1; then
        uci -q delete quecmanager.at 2>/dev/null
        info "Removed retired quecmanager.at section (legacy AT engine)"
    fi

    # Host AT ports (vendor port-bridge) — on by default, matching stock firmware.
    if ! uci -q get quecmanager.ports >/dev/null 2>&1; then
        uci set quecmanager.ports=ports
    fi
    if ! uci -q get quecmanager.ports.host_at >/dev/null 2>&1; then
        uci set quecmanager.ports.host_at=1
        info "Seeded quecmanager.ports.host_at=1 (on by default)"
    else
        info "quecmanager.ports.host_at already set — preserving user choice"
    fi

    # Prometheus metrics endpoint — opt-in, off by default. The bearer token is
    # NEVER seeded: the settings CGI generates it on first enable, and it stays
    # out of config backups. Idempotent + preserve-user-choice across upgrade.
    if ! uci -q get quecmanager.metrics >/dev/null 2>&1; then
        uci set quecmanager.metrics=metrics
    fi
    if ! uci -q get quecmanager.metrics.enabled >/dev/null 2>&1; then
        uci set quecmanager.metrics.enabled='0'
        info "Seeded quecmanager.metrics.enabled=0 (off by default)"
    else
        info "quecmanager.metrics.enabled already set — preserving user choice"
    fi
    if ! uci -q get quecmanager.metrics.freshness >/dev/null 2>&1; then
        uci set quecmanager.metrics.freshness='adaptive'
        info "Seeded quecmanager.metrics.freshness=adaptive"
    else
        info "quecmanager.metrics.freshness already set — preserving user choice"
    fi

    # PCIe ASPM policy — applied at boot by qmanager_eth_link. The stock
    # platform default (powersupersave) causes RTL8125 TX watchdog timeouts, so
    # seed performance. Never overwrite an existing user choice.
    if ! uci -q get quecmanager.eth_link >/dev/null 2>&1; then
        uci set quecmanager.eth_link=eth_link
    fi
    if ! uci -q get quecmanager.eth_link.aspm_policy >/dev/null 2>&1; then
        uci set quecmanager.eth_link.aspm_policy='performance'
        info "Seeded quecmanager.eth_link.aspm_policy=performance"
    else
        info "quecmanager.eth_link.aspm_policy already set — preserving user choice"
    fi

    uci commit quecmanager 2>/dev/null || warn "uci commit quecmanager failed"

    seed_web_port

    # Point /usr/bin/qcmd + qsms + qmi at qmanager_atd (atomic symlink swap). Must run after
    # install_backend + install_bundled_binaries.
    if [ -f "$LIB_DIR/at_engine.sh" ]; then
        . "$LIB_DIR/at_engine.sh"
        if at_qcmd_link; then
            info "qcmd -> $(readlink "$BIN_DIR/qcmd" 2>/dev/null)"
        else
            warn "Could not repoint $BIN_DIR/qcmd — AT commands may be unavailable"
        fi
        if at_qsms_link; then
            info "qsms -> $(readlink "$BIN_DIR/qsms" 2>/dev/null)"
        else
            warn "Could not link $BIN_DIR/qsms — SMS may be unavailable"
        fi
        if at_qmi_link; then
            info "qmi -> $(readlink "$BIN_DIR/qmi" 2>/dev/null)"
        else
            warn "Could not link $BIN_DIR/qmi — QMI client unavailable"
        fi
        # Runs after install_frontend (its /www wipe removes the link).
        if at_live_link; then
            info "qmlive -> $(readlink "$WWW_ROOT/qmlive" 2>/dev/null)"
        else
            warn "Could not link $WWW_ROOT/qmlive — real-time signal unavailable"
        fi
    else
        warn "at_engine.sh missing — /usr/bin/qcmd, qsms and qmi not linked"
    fi
}

enable_services() {
    step "Enabling init.d services"

    # Every qmanager* service gets enabled unconditionally UNLESS it is in
    # UCI_GATED_SERVICES. Gated services are only enabled if a prior install
    # had them enabled (detected via /etc/rc.d symlink presence).
    for svc in "$INITD_DIR"/qmanager*; do
        [ -x "$svc" ] || continue
        local name
        name="$(basename "$svc")"

        local gated=0
        for g in $UCI_GATED_SERVICES; do
            [ "$name" = "$g" ] && gated=1 && break
        done

        if [ "$gated" = "0" ]; then
            "$svc" enable >>"$LOG_FILE" 2>&1 || warn "Failed to enable $name"
            info "Enabled $name"
            continue
        fi

        local was_enabled=0
        for rc in /etc/rc.d/*"$name"*; do
            [ -e "$rc" ] && was_enabled=1 && break
        done

        if [ "$was_enabled" = "1" ]; then
            "$svc" enable >>"$LOG_FILE" 2>&1 || warn "Failed to enable $name"
            info "Enabled $name (preserving previous state)"
        else
            info "Skipped $name (UCI-gated, enable manually if needed)"
        fi
    done
}

start_services() {
    step "Starting QManager services"

    # AT broker first (boot order START=98 before qmanager's 99), so the poller's
    # first AT call goes through it. qcmd works without it (in-process fallback).
    if [ -x "$INITD_DIR/qmanager_atd" ]; then
        "$INITD_DIR/qmanager_atd" start >>"$LOG_FILE" 2>&1 \
            || warn "Failed to start AT broker (qcmd falls back to in-process)"
        info "Started AT broker"
    fi

    if [ -x "$INITD_DIR/qmanager" ]; then
        "$INITD_DIR/qmanager" start >>"$LOG_FILE" 2>&1 \
            || warn "Failed to start main qmanager service"
        info "Started main qmanager service"
    fi

    # Sites monitor: not UCI-gated (on/off lives in /etc/qmanager/sites.json).
    # Started here because OTA runs --no-reboot; boot starts it via rc.d.
    if [ -x "$INITD_DIR/qmanager_sites" ]; then
        "$INITD_DIR/qmanager_sites" start >>"$LOG_FILE" 2>&1 \
            || warn "Failed to start Sites monitor"
        info "Started Sites monitor"
    fi

    restore_running_services
}

# Restart every service snapshot_running_services saw running (B5.27). Each
# gated service's start re-checks its own UCI/config flag, so this never
# force-enables a feature. Watchcat starts while the maintenance lock is
# still held and resumes when main() removes it.
restore_running_services() {
    local name
    for name in $RUNNING_BEFORE_STOP; do
        # Under --configure the list comes back from a /tmp file, so only a
        # plain qmanager* service name may reach the init.d call below.
        case "$name" in
            qmanager_atd|qmanager|qmanager_sites) continue ;;
            *[!A-Za-z0-9_]*) continue ;;
            qmanager*) ;;
            *) continue ;;
        esac
        [ -x "$INITD_DIR/$name" ] || continue
        "$INITD_DIR/$name" start >>"$LOG_FILE" 2>&1 \
            || warn "Failed to restart $name"
        info "Restarted $name (was running before install)"
    done
}

# --- File Install Steps ------------------------------------------------------

backup_originals() {
    step "Backing up original files"

    mkdir -p "$BACKUP_DIR"

    if [ ! -f "$WWW_ROOT/index.html.old" ] && [ -f "$WWW_ROOT/index.html" ]; then
        if grep -q "QManager" "$WWW_ROOT/index.html" 2>/dev/null; then
            info "Existing index.html is already QManager — skipping backup"
        else
            mv "$WWW_ROOT/index.html" "$WWW_ROOT/index.html.old"
            info "Backed up /www/index.html -> index.html.old"
        fi
    elif [ -f "$WWW_ROOT/index.html.old" ]; then
        info "Original index.html.old already preserved"
    else
        info "No existing index.html to back up"
    fi

    if [ -f "$CONF_DIR/auth.json" ]; then
        local ts
        ts=$(date +%Y%m%d_%H%M%S)
        cp "$CONF_DIR/auth.json" "$BACKUP_DIR/auth.json.$ts" 2>/dev/null || true
        info "Backed up password hash ($BACKUP_DIR/auth.json.$ts)"
    fi
}

install_frontend() {
    step "Installing frontend"

    # Wipe /www/* except preserved items (intentional per project decision)
    for item in "$WWW_ROOT"/*; do
        [ -e "$item" ] || continue
        local name
        name="$(basename "$item")"
        case "$name" in
            cgi-bin|luci-static|index.html.old) continue ;;
            *) rm -rf "$item" ;;
        esac
    done

    cp -r "$SRC_FRONTEND"/. "$WWW_ROOT"/ || die "Failed to copy frontend to $WWW_ROOT"

    local n
    n=$(count_files "$SRC_FRONTEND")
    info "Frontend installed ($n files)"

    # The /www wipe above removed the live-signal link. Frontend-only installs
    # do not reach the at_engine block in seed_uci_defaults, so restore it here
    # when the installed library already has the helper (a fresh install gets it
    # from that block once install_backend has placed the library).
    # Subshell: on OTA this is still the previous release's library, and sourcing
    # it here would set _AT_ENGINE_LOADED and shadow the new one in seed_uci_defaults.
    if [ -f "$LIB_DIR/at_engine.sh" ]; then
        ( . "$LIB_DIR/at_engine.sh"
          command -v at_live_link >/dev/null 2>&1 || exit 0
          at_live_link ) || warn "Could not link $WWW_ROOT/qmlive — real-time signal unavailable"
    fi
}

install_backend() {
    step "Installing backend scripts"

    # --- Libraries (flat directory) ---
    if [ -d "$SRC_SCRIPTS/usr/lib/qmanager" ]; then
        local lib_count
        install_dir_flat "$SRC_SCRIPTS/usr/lib/qmanager" "$LIB_DIR" 755
        lib_count=$INSTALL_DIR_FLAT_COUNT
        # Non-.sh files in the lib dir should be 644
        find "$LIB_DIR" -maxdepth 1 -type f ! -name "*.sh" -exec chmod 644 {} \; 2>/dev/null
        info "Libraries: $lib_count files -> $LIB_DIR"
    fi

    # --- Daemons and utilities (flat) ---
    if [ -d "$SRC_SCRIPTS/usr/bin" ]; then
        local bin_count
        install_dir_flat "$SRC_SCRIPTS/usr/bin" "$BIN_DIR" 755
        bin_count=$INSTALL_DIR_FLAT_COUNT
        info "Daemons: $bin_count files -> $BIN_DIR"
    fi

    # --- CGI endpoints (recursive) ---
    if [ -d "$SRC_SCRIPTS/www/cgi-bin/quecmanager" ]; then
        install_tree "$SRC_SCRIPTS/www/cgi-bin/quecmanager" "$CGI_DIR"
        local cgi_count
        cgi_count=$(find "$CGI_DIR" -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')
        info "CGI endpoints: $cgi_count scripts -> $CGI_DIR"

        # Retired alert CGIs superseded by monitoring/alerts.sh. Unconditional
        # (harmless no-op on fresh installs; drops stale device copies on
        # upgrade so the old endpoints stop answering). Runs AFTER install_tree,
        # which no longer ships these four files.
        local _stale
        for _stale in sms_alerts.sh email_alerts.sh sms_alert_log.sh email_alert_log.sh; do
            if [ -f "$CGI_DIR/monitoring/$_stale" ]; then
                rm -f "$CGI_DIR/monitoring/$_stale"
                info "  Removed retired CGI: monitoring/$_stale"
            fi
        done

        # Retired AT engine switch (the broker is the only engine now).
        if [ -f "$CGI_DIR/system/at_engine.sh" ]; then
            rm -f "$CGI_DIR/system/at_engine.sh"
            info "  Removed retired CGI: system/at_engine.sh"
        fi
    fi

    # --- Init.d services (flat) ---
    if [ -d "$SRC_SCRIPTS/etc/init.d" ]; then
        local svc_count
        install_dir_flat "$SRC_SCRIPTS/etc/init.d" "$INITD_DIR" 755
        svc_count=$INSTALL_DIR_FLAT_COUNT
        info "Init.d: $svc_count services -> $INITD_DIR"
    fi

    # --- nftables.d files (persistent firewall rules) ---
    if [ -d "$SRC_SCRIPTS/etc/nftables.d" ]; then
        mkdir -p /etc/nftables.d
        local nft_count=0
        for f in "$SRC_SCRIPTS/etc/nftables.d"/*.nft; do
            [ -f "$f" ] || continue
            local fname
            fname="$(basename "$f")"
            if install_file "$f" "/etc/nftables.d/$fname" 644; then
                nft_count=$(( nft_count + 1 ))
            fi
        done
        info "nftables.d: $nft_count rule files -> /etc/nftables.d"
        # Trigger fw4 reload so rules take effect on running system (OTA --no-reboot path)
        if command -v fw4 >/dev/null 2>&1; then
            fw4 reload >/dev/null 2>&1 || true
        fi
    fi

    # --- sysctl.d hardening (B5.10: fs.protected_regular / protected_fifos) ---
    # /etc/init.d/sysctl applies /etc/sysctl.d/*.conf at boot; apply it live too
    # so an OTA --no-reboot upgrade is protected without waiting for a reboot.
    if [ -d "$SRC_SCRIPTS/etc/sysctl.d" ]; then
        mkdir -p /etc/sysctl.d
        for f in "$SRC_SCRIPTS/etc/sysctl.d"/*.conf; do
            [ -f "$f" ] || continue
            local sname
            sname="$(basename "$f")"
            if install_file "$f" "/etc/sysctl.d/$sname" 644; then
                sysctl -p "/etc/sysctl.d/$sname" >/dev/null 2>&1 \
                    || warn "sysctl: could not apply /etc/sysctl.d/$sname live"
                info "sysctl.d: $sname applied"
            fi
        done
    fi

    seed_runtime_files

    info "Backend installed"
}

# Runtime directories, deploy-if-missing default configs, the alert routing
# seed and the UCI stub. Shared by the tarball install (after install_backend
# copied the tree) and the package --configure path (defaults ship under
# $IPK_DEFAULTS there, since opkg must not own user-editable config).
seed_runtime_files() {
    local defaults="$SRC_SCRIPTS/etc/qmanager"
    [ "$CONFIGURE" = "1" ] && defaults="$IPK_DEFAULTS"

    # --- Required runtime directories ---
    # The session dir is not pre-created: cgi_auth.sh makes it root-owned on
    # first login and refuses one another user created first (B4.1).
    mkdir -p "$CONF_DIR/profiles" "$UPDATES_DIR" /var/lock

    # Sites monitor rollups: daemon-written hourly JSONL, CGI read-only. The device
    # has no `install` applet; the explicit chown/chmod also fix a re-install.
    if mkdir -p /usrdata/qmanager/sites 2>>"$LOG_FILE"; then
        chown root:root /usrdata/qmanager/sites 2>/dev/null || true
        chmod 0755 /usrdata/qmanager/sites 2>/dev/null || true
    else
        warn "Could not create /usrdata/qmanager/sites (Sites history will retry at runtime)"
    fi

    # --- Default config files (deploy ONLY if missing, never overwrite) ---
    # Exception: supported_bands_hw.env is a manually-maintained spec-sheet file
    # that MUST refresh on every upgrade, so it is force-copied below (outside the
    # deploy-if-missing loop) rather than treated as user-owned config.
    if [ -d "$defaults" ]; then
        local deployed=0
        for f in "$defaults"/*; do
            [ -f "$f" ] || continue
            local fname
            fname="$(basename "$f")"
            [ "$fname" = "supported_bands_hw.env" ] && continue
            if [ ! -f "$CONF_DIR/$fname" ]; then
                cp "$f" "$CONF_DIR/$fname"
                deployed=$(( deployed + 1 ))
                info "  Deployed default config: $fname"
            fi
        done
        [ "$deployed" = "0" ] && info "  All default configs already present"

        # Force-copy the hardware band-capability file every install/upgrade so
        # spec/firmware edits in the repo always reach the device.
        if [ -f "$defaults/supported_bands_hw.env" ]; then
            cp "$defaults/supported_bands_hw.env" "$CONF_DIR/supported_bands_hw.env"
            info "  Force-deployed hardware band capability: supported_bands_hw.env"
        fi
    fi

    # --- Seed centralized alert routing (idempotent — never overwrite) ---
    # New additive file; absence would fail-close to the same defaults, but
    # seeding it makes the routing visible/editable from first boot. Sourced in
    # a subshell so the lib's globals don't leak into the installer namespace.
    if [ ! -f "$CONF_DIR/alert_routing.json" ]; then
        local _ar_seed=""
        if [ -f "$LIB_DIR/alert_routing.sh" ]; then
            _ar_seed=$( . "$LIB_DIR/alert_routing.sh" 2>/dev/null && alert_default_routing_json 2>/dev/null )
        fi
        case "$_ar_seed" in
            '{'*'}')
                printf '%s\n' "$_ar_seed" > "$CONF_DIR/alert_routing.json"
                info "  Seeded default alert routing: alert_routing.json"
                ;;
            *)
                warn "  Could not seed alert_routing.json (alert_routing.sh missing?) — routing will fail-close to defaults"
                ;;
        esac
    fi

    # UCI config stub
    [ -f /etc/config/quecmanager ] || touch /etc/config/quecmanager
}

install_bundled_binaries() {
    step "Installing bundled binaries (qmanager_atd)"

    [ -d "$SRC_DEPS" ] || die "Bundled dependencies not found: $SRC_DEPS"

    # qmanager_atd is the Rust AT broker. /usr/bin/qcmd becomes a symlink to it
    # in seed_uci_defaults.
    for bin in qmanager_atd; do
        local src="$SRC_DEPS/$bin"
        local dst="$BIN_DIR/$bin"

        [ -f "$src" ] || die "Missing required binary: dependencies/$bin"

        if ! install_file "$src" "$dst" 755; then
            die "Failed to install $bin (file busy? Ensure stop_services ran first)"
        fi
        info "Installed $bin -> $dst"
    done

    remove_legacy_at_engine

    # Smoke test (warn-only — modem may not be ready yet on fresh hardware).
    # The broker is stopped here, so this exercises the in-process path.
    local smoke
    smoke=$(run_atd_qcmd 5 "$BIN_DIR/qmanager_atd" 'AT' 2>/dev/null || true)
    if printf '%s\n' "$smoke" | grep -q OK; then
        info "qmanager_atd smoke test passed"
    else
        warn "qmanager_atd smoke test did not return OK — check /dev/smd11"
    fi
}

# Legacy AT engine (removed): the shell gatekeeper and the atcli binary it
# drove. If /usr/bin/qcmd still points at qcmd.sh it dangles until
# seed_uci_defaults repoints it; services are stopped meanwhile.
# sms_tool (retired in SMS phase 4): every caller uses qsms through the
# broker, which must be the only opener of /dev/smd11.
remove_legacy_at_engine() {
    local old
    for old in qcmd.sh atcli_smd11 sms_tool; do
        if [ -e "$BIN_DIR/$old" ]; then
            rm -f "$BIN_DIR/$old"
            info "Removed legacy AT engine file: $old"
        fi
    done
}

# --- Tailscale Network Fixes Migration ---------------------------------------
# Owns the OTA side of the Tailscale network fixes (fw4 zone + `ip rule ...
# pref 1990` routing rule, see usr/lib/qmanager/tailscale_net.sh):
#   1. Retires the old opt-in `quecmanager.tailscale_workarounds` key. Its seeded
#      0 cannot be told apart from a user choice, and the new default is ON, so
#      the replacement `quecmanager.tailscale_net.enabled` is forced to 1.
#   2. When a Tailscale binary is present and the fixes are not switched off,
#      applies the rule and (idempotently) the zone right away, so the OTA
#      --no-reboot path is reachable over Tailscale without waiting for a boot.
# The legacy zone is no longer deleted. Idempotent — a fast no-op once migrated.
# Must run AFTER install_backend: it sources the freshly copied tailscale_net.sh.

migrate_tailscale_net() {
    step "Migrating Tailscale network fixes"

    if ! command -v uci >/dev/null 2>&1; then
        info "uci not available — skipping Tailscale network migration"
        return 0
    fi

    if uci -q get quecmanager.tailscale_workarounds >/dev/null 2>&1; then
        uci -q delete quecmanager.tailscale_workarounds 2>/dev/null || true
        if ! uci -q get quecmanager.tailscale_net >/dev/null 2>&1; then
            uci set quecmanager.tailscale_net=tailscale_net 2>/dev/null || true
        fi
        uci set quecmanager.tailscale_net.enabled=1 2>/dev/null || true
        if uci commit quecmanager 2>/dev/null; then
            info "Retired quecmanager.tailscale_workarounds; tailscale_net.enabled=1"
        else
            warn "uci commit quecmanager failed — Tailscale network migration may not persist"
        fi
    fi

    if [ ! -x /usr/bin/tailscale ] && [ ! -x /usr/sbin/tailscale ]; then
        info "Tailscale not installed — nothing to apply"
        return 0
    fi

    if [ "$(uci -q get quecmanager.tailscale_net.enabled 2>/dev/null)" = "0" ]; then
        info "Tailscale network fixes switched off — leaving as-is"
        return 0
    fi

    local lib="$LIB_DIR/tailscale_net.sh"
    if [ ! -f "$lib" ]; then
        warn "tailscale_net.sh missing — Tailscale network fixes not applied"
        return 0
    fi

    # Subshell: the lib's names and any failure stay out of the installer.
    # Rules are cheap; the zone only reloads fw4 when it actually changed.
    if (
        . "$lib"
        ts_net_ensure_rules
        if ts_net_ensure_zone; then
            ts_net_fw_reload
        fi
    ) >>"$LOG_FILE" 2>&1; then
        info "Tailscale network fixes applied (ip rule + fw4 zone)"
    else
        warn "Tailscale network fixes could not be applied; qmanager_tailscale_net retries at boot"
    fi
    return 0
}

# Refreshes the official-variant Tailscale procd init script so its stop hook
# no longer runs `tailscale down` (which persisted WantRunning=false and
# stranded the node disconnected across reboots). Existing official installs
# carry the old init on disk; the CGI heredoc fix only affects fresh installs,
# so OTA upgrades self-heal here. OFFICIAL VARIANT ONLY — no-op for tiny/opkg
# or any install without the marker. Idempotent.
migrate_tailscale_initd_boot_fix() {
    [ "$(cat /etc/tailscale/.qm_install_method 2>/dev/null | tr -d ' \n\r')" = "official" ] || return 0
    if [ ! -f /usr/lib/qmanager/tailscale_initd.sh ]; then
        warn "Official Tailscale init refresh skipped — tailscale_initd.sh lib missing"
        return 0
    fi
    . /usr/lib/qmanager/tailscale_initd.sh
    qm_write_ts_initd
    info "Refreshed official Tailscale init script (boot-reconnect fix)"
}

# --- Cleanup Legacy ----------------------------------------------------------
# Removes qmanager_* files on disk that are NOT in the fresh source tree.
# This is the ONLY place where legacy cleanup happens — integrated into the
# install path rather than a separate pass.

# True when the release being installed ships <root-relative path>: the
# tarball's scripts/ tree, or the package manifest under --configure.
src_has() {
    if [ "$CONFIGURE" = "1" ]; then
        grep -qxF "$1" "$IPK_MANIFEST" 2>/dev/null
    else
        [ -f "$SRC_SCRIPTS/$1" ]
    fi
}

cleanup_legacy_scripts() {
    step "Cleaning up legacy scripts"

    local removed=0 fname

    # Retire the legacy qmanager_wan_guard daemon (removed in this version). OTA
    # overlays do not prune absent-from-tree files, so remove it explicitly on
    # upgraded devices. Idempotent — silent no-op on fresh installs. The generic
    # loops below would also catch it, but this guarantees the running daemon is
    # stopped and the binary gone before enable_services runs.
    if [ -f "$INITD_DIR/qmanager_wan_guard" ]; then
        "$INITD_DIR/qmanager_wan_guard" stop 2>/dev/null || true
        "$INITD_DIR/qmanager_wan_guard" disable 2>/dev/null || true
        rm -f "$INITD_DIR/qmanager_wan_guard"
        info "  Retired legacy daemon: qmanager_wan_guard"
    fi
    rm -f "$BIN_DIR/qmanager_wan_guard"
    rm -f /etc/rc.d/*qmanager_wan_guard 2>/dev/null || true

    # Retire the Tailscale zone boot self-heal (qmanager_vpn_zone) and its
    # vpn_firewall.sh lib, replaced by qmanager_tailscale_net + tailscale_net.sh.
    # Explicit so the legacy init is disabled (rc.d links gone) before
    # enable_services runs, even if the generic loops below change. Idempotent.
    # Does not touch the live fw4 zone: migrate_tailscale_net keeps/re-adopts it.
    if [ -f "$INITD_DIR/qmanager_vpn_zone" ]; then
        "$INITD_DIR/qmanager_vpn_zone" disable 2>/dev/null || true
        rm -f "$INITD_DIR/qmanager_vpn_zone"
        info "  Retired legacy service: qmanager_vpn_zone"
    fi
    rm -f /etc/rc.d/*qmanager_vpn_zone 2>/dev/null || true
    if [ -f "$LIB_DIR/vpn_firewall.sh" ]; then
        rm -f "$LIB_DIR/vpn_firewall.sh"
        info "  Retired legacy library: vpn_firewall.sh"
    fi

    # Retire orphaned Wake-on-LAN UCI flag (WoL feature removed). Key-only
    # delete — preserves the quecmanager.network section in case a SKU adds
    # sibling keys. The qmanager_wol_fix init.d is auto-pruned by the stale
    # init.d loop below; wol.sh CGI is harmless if it lingers.
    uci -q delete quecmanager.network.disable_wol 2>/dev/null && uci -q commit quecmanager 2>/dev/null || true

    # Daemons: /usr/bin/qmanager_*, qcmd, bridge_traffic_monitor_*
    for f in "$BIN_DIR"/qmanager_* "$BIN_DIR/qcmd" "$BIN_DIR"/bridge_traffic_monitor_*; do
        [ -f "$f" ] || continue
        fname="$(basename "$f")"
        src_has "usr/bin/$fname" && continue
        # Not legacy: qmanager_atd ships from dependencies/, and /usr/bin/qcmd
        # is the symlink to it that seed_uci_defaults (re)creates.
        case "$fname" in qmanager_atd|qcmd) continue ;; esac
        rm -f "$f"
        info "  Removed legacy daemon: $fname"
        removed=$(( removed + 1 ))
    done

    # Init.d services
    for f in "$INITD_DIR"/qmanager*; do
        [ -f "$f" ] || continue
        fname="$(basename "$f")"
        src_has "etc/init.d/$fname" && continue
        "$f" disable 2>/dev/null || true
        "$f" stop 2>/dev/null || true
        rm -f "$f"
        for _link in /etc/rc.d/*"$fname"*; do
            [ -e "$_link" ] && rm -f "$_link"
        done
        info "  Removed legacy service: $fname"
        removed=$(( removed + 1 ))
    done

    # Libraries
    if [ -d "$LIB_DIR" ]; then
        for f in "$LIB_DIR"/*; do
            [ -f "$f" ] || continue
            fname="$(basename "$f")"
            src_has "usr/lib/qmanager/$fname" && continue
            rm -f "$f"
            info "  Removed legacy library: $fname"
            removed=$(( removed + 1 ))
        done
    fi

    if [ "$removed" = "0" ]; then
        info "No legacy scripts found"
    else
        info "Removed $removed legacy file(s)"
    fi
}

# --- Post-install Health Check -----------------------------------------------

health_check() {
    step "Post-install health check"

    sleep 2

    local poller_pid
    local ping_pid
    poller_pid=$(pidof qmanager_poller 2>/dev/null || true)
    ping_pid=$(pidof qmanager_ping 2>/dev/null || true)

    if [ -n "$poller_pid" ]; then
        info "Poller running (PID: $poller_pid)"
    else
        warn "Poller does not appear to be running"
    fi

    if [ -n "$ping_pid" ]; then
        info "Ping daemon running (PID: $ping_pid)"
    else
        warn "Ping daemon does not appear to be running"
    fi

    # Wait up to 10s for the poller to produce its status cache. Stronger
    # health signal than just pidof.
    local i=0
    while [ "$i" -lt 10 ]; do
        if [ -f /tmp/qmanager_status.json ]; then
            info "Poller status cache is live (/tmp/qmanager_status.json)"
            return 0
        fi
        sleep 1
        i=$(( i + 1 ))
    done

    warn "Poller did not produce /tmp/qmanager_status.json within 10s"
    warn "Service may still be initializing — check /tmp/qmanager.log"
}

# --- AT Stack Verification ---------------------------------------------------
# Runs at the very end of install, before reboot, to confirm that the full AT
# command pipeline (qcmd → qmanager_atd → /dev/smd11) is working. This catches
# the scenario where install "succeeds" but AT commands are silently broken
# (e.g., leftover conflicting process holding /dev/smd11, wrong binary, perms).
# Warn-only with retries — fresh hardware may need a few seconds after services
# start before the modem accepts AT traffic on /dev/smd11.

at_stack_check() {
    step "Verifying AT command stack (qcmd ATI)"

    if ! command -v qcmd >/dev/null 2>&1; then
        warn "qcmd not found on PATH — skipping AT stack check"
        return 0
    fi

    local out="" i=0
    while [ "$i" -lt 3 ]; do
        out=$(run_capture_timeout 8 qcmd 'ATI' 2>/dev/null || true)
        if printf '%s\n' "$out" | grep -q '^OK'; then
            info "qcmd ATI → OK (AT stack verified)"
            local model
            model=$(printf '%s\n' "$out" | grep -iE 'quectel|RM[0-9]+|EG[0-9]+' | head -n1 | tr -d '\r')
            [ -n "$model" ] && info "Modem reports: $model"
            return 0
        fi
        i=$(( i + 1 ))
        [ "$i" -lt 3 ] && sleep 2
    done

    warn "qcmd ATI did not return OK after 3 attempts"
    warn "  Troubleshooting:"
    warn "    1. Check /dev/smd11 exists: ls -la /dev/smd11"
    warn "    2. Check the qcmd link:     ls -la /usr/bin/qcmd  (-> qmanager_atd)"
    warn "       Then test directly:    qcmd 'AT'"
    warn "    3. Check for conflicts:     opkg list-installed | grep -E 'sms-tool|socat'"
    warn "    4. Review install log:      $LOG_FILE"
    warn "  AT commands may start working once the modem finishes initializing."
    return 1
}

# --- Summary -----------------------------------------------------------------

print_summary() {
    printf "\n"
    if [ -t 1 ]; then
        printf "  [%s  100%%  Complete]\n" "$(_draw_bar "$TOTAL_STEPS" "$TOTAL_STEPS")"
    fi
    printf "\n"
    printf "  ══════════════════════════════════════════\n"
    printf "  ${GREEN}${BOLD}  QManager - Installation Complete${NC}\n"
    printf "  ══════════════════════════════════════════\n\n"

    printf "  ${DIM}Version:     ${NC}%s\n" "$VERSION"
    [ "$DO_FRONTEND" = "1" ] && printf "  ${DIM}Frontend:    ${NC}%s\n" "$WWW_ROOT"
    if [ "$DO_BACKEND" = "1" ]; then
        printf "  ${DIM}CGI:         ${NC}%s\n" "$CGI_DIR"
        printf "  ${DIM}Libraries:   ${NC}%s\n" "$LIB_DIR"
        printf "  ${DIM}Daemons:     ${NC}%s/qmanager_*\n" "$BIN_DIR"
        printf "  ${DIM}Init.d:      ${NC}%s/qmanager*\n" "$INITD_DIR"
        printf "  ${DIM}Config:      ${NC}%s\n" "$CONF_DIR"
        printf "  ${DIM}Install log: ${NC}%s\n" "$LOG_FILE"
    fi

    printf "\n"
    printf "  ${DIM}Packages:${NC}\n"
    for pkg in $REQUIRED_PACKAGES $OPTIONAL_PACKAGES; do
        if command -v "$(pkg_binary "$pkg")" >/dev/null 2>&1; then
            printf "    ${GREEN}${ICO_OK}${NC}  %-18s installed\n" "$pkg"
        else
            printf "    ${YELLOW}${ICO_WARN}${NC}  %-18s missing\n" "$pkg"
        fi
    done

    printf "\n"
    local device_ip
    device_ip=$(uci get network.lan.ipaddr 2>/dev/null | cut -d'/' -f1 || echo "192.168.1.1")
    local web_port=""
    command -v wp_conf_http >/dev/null 2>&1 && web_port=$(wp_conf_http)
    if [ -n "$web_port" ] && [ "$web_port" != "80" ]; then
        printf "  Open in browser:  ${BOLD}http://%s:%s${NC}\n\n" "$device_ip" "$web_port"
    else
        printf "  Open in browser:  ${BOLD}http://%s${NC}\n\n" "$device_ip"
    fi

    if [ ! -f "$CONF_DIR/auth.json" ]; then
        info "First-time setup: you will be prompted to create a password"
    fi
    printf "\n"
}

# --- Reboot ------------------------------------------------------------------

reboot_system() {
    # Best-effort planned-reboot breadcrumb so the post-update boot classifies
    # this as a user reboot (not an unplanned power loss). The lib was just
    # deployed by this same install run, so it is normally present; if absent we
    # simply skip — the poller then infers "unplanned", an acceptable degradation
    # for a broken install. GUARD with [ -f ] before dot-sourcing: a `.` on a
    # missing file ABORTS a non-interactive BusyBox ash script (POSIX special
    # builtin), which would kill install.sh before it ever reaches the reboot.
    [ -f /usr/lib/qmanager/qlog.sh ] && . /usr/lib/qmanager/qlog.sh
    [ -n "$(command -v record_planned_reboot)" ] && record_planned_reboot "user" 2>/dev/null
    flush_storage "pre-reboot"
    if command -v reboot >/dev/null 2>&1; then
        reboot
        return $?
    fi
    if [ -x /sbin/reboot ]; then
        /sbin/reboot
        return $?
    fi
    if command -v busybox >/dev/null 2>&1; then
        busybox reboot
        return $?
    fi
    die "Cannot find reboot command"
}

# --- Usage -------------------------------------------------------------------

usage() {
    cat <<EOF
QManager Installer $VERSION

Usage: sh install.sh [OPTIONS]

Options:
  --frontend-only    Only install frontend files
  --backend-only     Only install backend scripts
  --skip-packages    Skip opkg package install (used by OTA)
  --no-enable        Do not enable init.d services
  --no-start         Do not start services after install
  --no-reboot        Do not reboot after install (used by OTA)
  --force            Skip modem firmware detection
  --ignore-package   Install over an opkg-managed (sdxpinn-qmanager) install
  --configure        Package mode (ipk postinst): configure placed files
  --help, -h         Show this help

Archive layout:
  qmanager_install/
    install.sh         (this script)
    out/               (Next.js static export)
    scripts/           (backend tree)
    dependencies/      (bundled binaries)

Example:
  cd /tmp && tar xzf qmanager.tar.gz
  cd qmanager_install && sh install.sh
EOF
}

# --- Package (ipk) Lifecycle -------------------------------------------------
# opkg places the payload itself, so the package path reuses every phase above
# except the file copies:
#   preinst   = this script embedded by build-ipk.sh, QM_INSTALL_ENTRY=ipk_preinst
#               (the new files are not on disk yet, so it cannot be a path call)
#   postinst  = $IPK_SHARE_DIR/install.sh --configure
# Neither may call opkg (it holds the lock), prompt, or reboot.

# Remove files under <dir> that the package does not ship, then the emptied
# directories. A tarball install leaves files opkg does not track, and a
# removed Next.js chunk or CGI would otherwise linger forever. Top-level names
# in <keep> (space-separated) are never touched.
prune_unshipped() {
    local dir="$1"
    local keep=" $2 "
    local list item name f
    local n=0

    # -s, not -f: with an empty first file awk's NR == FNR reads the file
    # list as the manifest.
    [ -d "$dir" ] && [ -s "$IPK_MANIFEST" ] || return 0
    list=$(mktemp /tmp/qm_prune.XXXXXX) || return 0

    for item in "$dir"/*; do
        [ -e "$item" ] || [ -L "$item" ] || continue
        name="$(basename "$item")"
        case "$keep" in *" $name "*) continue ;; esac
        find "$item" -type f -o -type l
    done | awk 'NR == FNR { ship["/" $0] = 1; next } !($0 in ship)' "$IPK_MANIFEST" - > "$list"

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rm -f "$f" && n=$(( n + 1 ))
    done < "$list"
    rm -f "$list"

    for item in "$dir"/*; do
        [ -d "$item" ] && [ ! -L "$item" ] || continue
        name="$(basename "$item")"
        case "$keep" in *" $name "*) continue ;; esac
        find "$item" -depth -type d | while IFS= read -r f; do
            rmdir "$f" 2>/dev/null || true
        done
    done

    [ "$n" = "0" ] || info "Removed $n file(s) under $dir the package does not ship"
}

# Firmware gate for the package path: warn, never abort. Architecture
# "sdxpinn" already limits the package to the SDX75 family, and a failing
# postinst would only leave a half-configured package behind. The poller cache
# is read first so a stopped broker never costs an AT round-trip here.
preflight_configure() {
    step "Pre-flight checks"

    [ "$(id -u)" -eq 0 ] || die "This script must be run as root"
    # Every "does the package ship this?" test reads the manifest, so an empty
    # or cut-short one would delete the install. It always lists itself.
    [ -s "$IPK_MANIFEST" ] && grep -qxF "${IPK_MANIFEST#/}" "$IPK_MANIFEST"         || die "Package manifest is missing or damaged: $IPK_MANIFEST"

    local fw=""
    local cache
    for cache in /tmp/qmanager_status.json /etc/qmanager/status.json; do
        [ -f "$cache" ] || continue
        fw=$(tr -d '\r\n' < "$cache" \
            | sed -n 's/.*"device"[[:space:]]*:[[:space:]]*{[^}]*"firmware"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        [ -n "$fw" ] && break
    done
    [ -n "$fw" ] || fw=$(detect_modem_firmware || true)

    if [ -z "$fw" ]; then
        warn "Could not detect modem firmware; QManager supports the RM551E-GL"
    elif ! printf '%s' "$fw" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9' | grep -q "$REQUIRED_FIRMWARE"; then
        warn "Modem firmware $fw is not an RM551E-GL; some features may not work"
    else
        info "Modem firmware: $fw"
    fi
    info "Pre-flight checks passed"
}

# preinst: everything the tarball install does before it copies files, against
# the system as it is now. $1 is opkg's "install" or "upgrade".
ipk_preinst() {
    IN_OPKG=1
    DO_REBOOT=0
    TOTAL_STEPS=1

    # Release the watchcat lock only on failure; on success the postinst holds
    # it across the unpack and releases it after start_services.
    trap 'rm -f "$WATCHCAT_LOCK" 2>/dev/null || true' EXIT INT TERM

    log_init
    _log_raw "Package preinst ($1)"
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root"

    mark_version_pending
    retire_bandwidth_monitor
    retire_low_power
    stop_services
    printf '%s\n' "$RUNNING_BEFORE_STOP" > "$IPK_RUNNING_FILE"

    trap - EXIT INT TERM
}

# The preinst stopped every service, so a postinst that dies part-way must
# not leave the modem without its daemons until the next reboot.
configure_exit() {
    local rc=$?
    trap - EXIT INT TERM
    if [ "$rc" != "0" ] && [ "$SERVICES_STARTED" != "1" ]; then
        warn "Package configure failed (exit $rc); restarting services"
        DO_START=1
        start_services || true
    fi
    rm -f "$WATCHCAT_LOCK" /tmp/qm_prune.* 2>/dev/null || true
    exit "$rc"
}

# postinst (--configure): every post-copy phase of the tarball install, run
# over the files opkg just placed.
configure_main() {
    SERVICES_STARTED=0
    trap configure_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    IN_OPKG=1
    CONFIGURE=1
    DO_FRONTEND=1
    DO_BACKEND=1
    DO_REBOOT=0
    TOTAL_STEPS=9
    [ "$DO_ENABLE" = "1" ] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
    [ "$DO_START" = "1" ] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))

    log_init
    _log_raw "Package postinst (--configure)"

    preflight_configure
    prompt_web_port
    [ -f "$VERSION_PENDING" ] || mark_version_pending

    # Held since preinst; re-assert in case /tmp was touched in between.
    touch "$WATCHCAT_LOCK" 2>/dev/null || true
    RUNNING_BEFORE_STOP=$(cat "$IPK_RUNNING_FILE" 2>/dev/null || true)
    rm -f "$IPK_RUNNING_FILE"

    # LuCI's /www/index.html belongs to luci-base, so the package ships ours
    # under $IPK_SHARE_DIR and swaps it in (uninstall puts LuCI's back).
    backup_originals
    step "Installing frontend entry page"
    cp "$IPK_SHARE_DIR/index.html" "$WWW_ROOT/index.html" \
        || die "Failed to install $WWW_ROOT/index.html"
    info "Installed $WWW_ROOT/index.html"

    step "Removing files left by a previous install"
    prune_unshipped "$WWW_ROOT" "cgi-bin luci-static index.html index.html.old qmlive"
    prune_unshipped "$CGI_DIR" ""
    remove_legacy_at_engine

    step "Applying firewall and sysctl rules"
    if [ -f /etc/nftables.d/12-mangle-qmanager-dpi.nft ] && command -v fw4 >/dev/null 2>&1; then
        fw4 reload >/dev/null 2>&1 || true
        info "Reloaded fw4"
    fi
    local f
    for f in /etc/sysctl.d/90-qmanager-*.conf; do
        [ -f "$f" ] || continue
        sysctl -p "$f" >/dev/null 2>&1 || warn "sysctl: could not apply $f live"
        info "sysctl.d: $(basename "$f") applied"
    done

    step "Seeding runtime files"
    seed_runtime_files

    cleanup_legacy_scripts
    migrate_tailscale_net
    migrate_tailscale_initd_boot_fix || warn "Tailscale initd boot-fix returned non-zero; continuing install"
    seed_uci_defaults
    flush_storage "pre-start"

    [ "$DO_ENABLE" = "1" ] && enable_services
    if [ "$DO_START" = "1" ]; then
        start_services
    fi
    SERVICES_STARTED=1
    rm -f "$WATCHCAT_LOCK" 2>/dev/null || true

    finalize_version
    # The OTA path reboots after every install; the package path never
    # reboots on its own, so it asks through the app's deferred-reboot banner.
    touch "$IPK_REBOOT_FLAG" 2>/dev/null || true
    flush_storage "install complete"
    print_summary
    info "Reboot the modem to finish the update"
}

# --- Main --------------------------------------------------------------------

main() {
    DO_FRONTEND=1
    DO_BACKEND=1
    DO_ENABLE=1
    DO_START=1
    DO_PACKAGES=1
    DO_REBOOT=1
    DO_FORCE=0
    DO_IGNORE_PACKAGE=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --configure)     CONFIGURE=1 ;;
            --ignore-package) DO_IGNORE_PACKAGE=1 ;;
            --frontend-only) DO_FRONTEND=1; DO_BACKEND=0 ;;
            --backend-only)  DO_FRONTEND=0; DO_BACKEND=1 ;;
            --skip-packages) DO_PACKAGES=0 ;;
            --no-enable)     DO_ENABLE=0 ;;
            --no-start)      DO_START=0 ;;
            --no-reboot)     DO_REBOOT=0 ;;
            --force)         DO_FORCE=1 ;;
            --help|-h)       usage; exit 0 ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done

    if [ "$CONFIGURE" = "1" ]; then
        configure_main
        return 0
    fi

    # opkg owns an ipk install's file list: a tarball install over it (manual
    # or Software Update) would leave opkg removing and upgrading the wrong
    # files. Update the package through opkg instead.
    if [ -f "$IPK_INFO" ] && [ "$DO_IGNORE_PACKAGE" = "0" ]; then
        error "QManager is installed as the $IPK_PACKAGE package."
        error "Update it with: opkg update && opkg upgrade $IPK_PACKAGE"
        error "To switch to a manual install, run first: opkg remove $IPK_PACKAGE"
        exit 1
    fi

    # Always release the watchcat lock on exit so a failed install doesn't
    # leave watchcat permanently in LOCKED state. /tmp clears on reboot but
    # if the user retries without rebooting, a stale lock would brick
    # connectivity monitoring until next boot. Set only past --help and the
    # package refusal: a refused run must not drop a lock a running opkg
    # transaction holds between preinst and postinst.
    trap 'rm -f "$WATCHCAT_LOCK" 2>/dev/null || true' EXIT INT TERM

    log_init

    # Compute total step count for the progress bar
    TOTAL_STEPS=1  # preflight
    TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))                                # remove_conflicts (always)
    [ "$DO_PACKAGES" = "1" ] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))    # install_packages
    TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))                                # stop_services
    if [ "$DO_FRONTEND" = "1" ]; then
        TOTAL_STEPS=$(( TOTAL_STEPS + 2 ))                            # backup + frontend
    fi
    if [ "$DO_BACKEND" = "1" ]; then
        TOTAL_STEPS=$(( TOTAL_STEPS + 5 ))                            # backend + bundled + cleanup + migrate_tailscale_net + seed
        [ "$DO_ENABLE" = "1" ] && TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))  # enable
        if [ "$DO_START" = "1" ]; then
            TOTAL_STEPS=$(( TOTAL_STEPS + 3 ))                        # start + health + at_stack_check
        fi
    fi

    # Banner
    printf "\n"
    printf "  ══════════════════════════════════════════\n"
    printf "  ${BOLD}  QManager - Installation Script${NC}\n"
    printf "  ${DIM}  Version: %s${NC}\n" "$VERSION"
    printf "  ══════════════════════════════════════════\n"

    preflight

    # Asked before any long-running work so the user answers up front.
    [ "$DO_BACKEND" = "1" ] && prompt_web_port

    mark_version_pending

    # Always run conflict removal — the conflicting opkg packages (sms-tool,
    # socat-at-bridge, socat) clobber /dev/smd11, which the AT broker owns,
    # regardless of whether we're installing opkg packages.
    # --skip-packages must not leave conflicts in place.
    remove_conflicts

    # Must run before stop_services and regardless of --skip-packages (OTA path).
    retire_bandwidth_monitor

    # Same rules; also before stop_services so qcmd can still restore CFUN=1.
    retire_low_power

    if [ "$DO_PACKAGES" = "1" ]; then
        install_packages
    fi

    stop_services

    if [ "$DO_FRONTEND" = "1" ]; then
        backup_originals
        install_frontend
    fi

    if [ "$DO_BACKEND" = "1" ]; then
        install_backend
        install_bundled_binaries
        cleanup_legacy_scripts
        migrate_tailscale_net
        migrate_tailscale_initd_boot_fix || warn "Tailscale initd boot-fix returned non-zero; continuing install"
        seed_uci_defaults

        # Everything is on disk; get it onto flash before restarting daemons,
        # which is where a hang (and a 0-byte-file power cycle) can follow.
        flush_storage "pre-start"

        [ "$DO_ENABLE" = "1" ] && enable_services

        if [ "$DO_START" = "1" ]; then
            start_services
            health_check
            at_stack_check || true
            # Release watchcat from maintenance mode now that install is
            # past the disruptive phases. Watchcat will exit LOCKED state
            # on its next loop iteration and resume normal monitoring.
            rm -f "$WATCHCAT_LOCK" 2>/dev/null || true
        fi
    fi

    finalize_version
    # Final flush: VERSION promotion, frontend-only installs, and anything the
    # start/health phases wrote. The OTA updater reboots right after we exit.
    flush_storage "install complete"
    print_summary

    if [ "$DO_REBOOT" = "1" ]; then
        printf "  Rebooting in 5 seconds — press Ctrl+C to cancel...\n\n"
        sleep 5
        reboot_system
    fi
}

case "${QM_INSTALL_ENTRY:-main}" in
    ipk_preinst) ipk_preinst "$@" ;;
    *)           main "$@" ;;
esac
