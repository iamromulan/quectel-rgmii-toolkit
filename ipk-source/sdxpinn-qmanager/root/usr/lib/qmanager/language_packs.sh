#!/bin/sh
# =============================================================================
# language_packs.sh — Shared helpers for language-pack install/list/remove
# =============================================================================
# Sourced by:
#   * /usr/bin/qmanager_language_install (worker)
#   * /www/cgi-bin/quecmanager/system/language-packs/list.sh
#   * /www/cgi-bin/quecmanager/system/language-packs/remove.sh
#
# Conventions:
#   * Callers own qlog_init. This library never calls it.
#   * Functions return 0 on success, non-zero on error. No side effects on
#     stdout unless documented.
#   * All jq expressions avoid test()/regex (OpenWRT jq lacks oniguruma).
#   * All jq boolean accesses use explicit if ... then ... else ... end.
# =============================================================================

[ -n "$_LP_LIB_LOADED" ] && return 0
_LP_LIB_LOADED=1
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

LP_LOCALES_DIR="/www/locales"
# B4.1: download/staging live under the root-only run dir (verify-then-extract swap)
LP_STAGING_DIR="/var/run/qmanager/lp_staging"
LP_DOWNLOAD_DIR="/var/run/qmanager/lp_download"
LP_PROGRESS_FILE="/tmp/qmanager_language_install.json"
LP_PID_FILE="/var/run/qmanager_language_install.pid"
LP_CANCEL_FILE="/tmp/qmanager_language_install.cancel"
LP_INPUT_FILE="/tmp/qmanager_language_install_input.json"

# Namespace files a valid pack must contain. Match ALL_NAMESPACES in
# lib/i18n/resources.ts so i18next-http-backend finds every namespace.
LP_REQUIRED_NS="common sidebar dashboard onboarding system-settings local-network monitoring events cellular"

# -----------------------------------------------------------------------------
# lp_pack_is_code_safe <code>
# Returns 0 if <code> matches BCP-47-ish pattern (letters, dash, digits only)
# and is short enough to be a filename segment. Guards against path traversal.
# -----------------------------------------------------------------------------
lp_pack_is_code_safe() {
    _c="$1"
    [ -z "$_c" ] && return 1
    # Length cap: BCP-47 tags rarely exceed 12 chars.
    _len=$(printf '%s' "$_c" | wc -c | tr -d ' ')
    [ "$_len" -gt 12 ] && return 1
    # Character class: [a-zA-Z0-9-]
    printf '%s' "$_c" | grep -qE '^[a-zA-Z0-9-]+$' || return 1
    # Reject leading/trailing hyphen and double-hyphen.
    case "$_c" in
        -*|*-) return 1 ;;
        *--*) return 1 ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# lp_list_installed
# Emits a JSON array of { code, version } by scanning /www/locales/<code>/
# directories. Empty array on missing directory. Stdout only.
# -----------------------------------------------------------------------------
lp_list_installed() {
    [ ! -d "$LP_LOCALES_DIR" ] && {
        echo '[]'
        return 0
    }
    _out="["
    _sep=""
    for _d in "$LP_LOCALES_DIR"/*; do
        [ -d "$_d" ] || continue
        _code=$(basename "$_d")
        lp_pack_is_code_safe "$_code" || continue
        _version=""
        if [ -f "$_d/.version" ]; then
            _version=$(head -c 64 "$_d/.version" 2>/dev/null | tr -d '\r\n' )
        fi
        _entry=$(jq -n --arg code "$_code" --arg version "$_version" \
            '{code:$code, version:$version}')
        _out="${_out}${_sep}${_entry}"
        _sep=","
    done
    _out="${_out}]"
    printf '%s\n' "$_out"
    return 0
}

# -----------------------------------------------------------------------------
# lp_fetch_manifest <url>
# Downloads the remote manifest JSON to stdout (NO progress side effects).
# Returns 0 on HTTP 200 + valid JSON, non-zero otherwise.
# -----------------------------------------------------------------------------
lp_fetch_manifest() {
    _url="$1"
    [ -z "$_url" ] && return 1
    _body=$(curl -sSfL -m 15 -H "User-Agent: QManager" "$_url" 2>/dev/null) || return 1
    [ -z "$_body" ] && return 1
    printf '%s' "$_body" | jq -e '.manifest_version == 1 and (.packs | type == "array")' >/dev/null 2>&1 || return 1
    printf '%s' "$_body"
    return 0
}

# -----------------------------------------------------------------------------
# lp_manifest_find_pack <manifest_body> <code>
# Emits the single pack entry from the manifest matching <code>, or empty
# string if not found. Uses plain string equality (no jq regex).
# -----------------------------------------------------------------------------
lp_manifest_find_pack() {
    _body="$1"
    _code="$2"
    printf '%s' "$_body" | jq -c --arg code "$_code" \
        '.packs[] | select(.code == $code)' 2>/dev/null
}

# -----------------------------------------------------------------------------
# lp_verify_sha256 <file> <expected_hex>
# Returns 0 if sha256 matches, 1 otherwise. Case-insensitive hex compare.
# -----------------------------------------------------------------------------
lp_verify_sha256() {
    _file="$1"
    _expected="$2"
    [ -f "$_file" ] || return 1
    [ -n "$_expected" ] || return 1
    _actual=$(sha256sum "$_file" 2>/dev/null | awk '{print $1}')
    [ -z "$_actual" ] && return 1
    # Normalize to lower-case for comparison.
    _expected_lc=$(printf '%s' "$_expected" | tr 'A-Z' 'a-z')
    _actual_lc=$(printf '%s' "$_actual" | tr 'A-Z' 'a-z')
    [ "$_actual_lc" = "$_expected_lc" ]
}

# -----------------------------------------------------------------------------
# lp_validate_pack_tree <dir>
# Returns 0 if <dir> contains every required namespace .json file AND each
# one parses as valid JSON. Returns 1 otherwise.
# -----------------------------------------------------------------------------
lp_validate_pack_tree() {
    _dir="$1"
    [ -d "$_dir" ] || return 1
    for _ns in $LP_REQUIRED_NS; do
        _f="$_dir/$_ns.json"
        [ -f "$_f" ] || return 1
        jq -e '.' "$_f" >/dev/null 2>&1 || return 1
    done
    return 0
}

# -----------------------------------------------------------------------------
# lp_remove_pack <code>
# Removes /www/locales/<code>/ if it exists. Safe — validates code first.
# Returns 0 on success, 1 on invalid code, 2 on filesystem error.
# -----------------------------------------------------------------------------
lp_remove_pack() {
    _code="$1"
    lp_pack_is_code_safe "$_code" || return 1
    _target="$LP_LOCALES_DIR/$_code"
    [ -d "$_target" ] || return 0
    rm -rf "$_target" 2>/dev/null || return 2
    return 0
}

# -----------------------------------------------------------------------------
# lp_disk_free_kb
# Emits the free space on /www in KB (1K blocks). Empty on error.
# -----------------------------------------------------------------------------
lp_disk_free_kb() {
    df "$LP_LOCALES_DIR" 2>/dev/null | awk 'NR==2 {print $4}'
}

# -----------------------------------------------------------------------------
# lp_write_progress <state> <code> <progress_int> <step> [<message>]
# Emits a single JSON document to $LP_PROGRESS_FILE atomically.
# state: "idle" | "running" | "success" | "failed" | "cancelled"
# step:  stable enum the frontend translates ("start" | "fetch_catalog" |
#        "download" | "verify" | "extract" | "validate" | "install" | "done" |
#        "cancelled" | "failed"). Empty for ad-hoc messages (e.g. error detail).
# message: optional human fallback string. Frontend prefers translated step.
# progress: integer 0-100
# -----------------------------------------------------------------------------
lp_write_progress() {
    _state="$1"
    _code="$2"
    _progress="$3"
    _step="$4"
    _message="${5:-}"
    jq -n \
        --arg state "$_state" \
        --arg code "${_code:-}" \
        --argjson progress "${_progress:-0}" \
        --arg step "${_step:-}" \
        --arg message "$_message" \
        '{state:$state, code:$code, progress:$progress, step:$step, message:$message}' \
        > "${LP_PROGRESS_FILE}.tmp" 2>/dev/null
    mv "${LP_PROGRESS_FILE}.tmp" "$LP_PROGRESS_FILE" 2>/dev/null
    return 0
}
