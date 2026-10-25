#!/bin/sh
# api_auth.sh — bearer-token auth for machine-facing CGI endpoints (scopes).
#
# A scope is one UCI section, quecmanager.<scope>, of type <scope>, with:
#   enabled   '1' to accept requests; anything else denies
#   token     exactly 64 lowercase hex; anything else is treated as no token
# plus any scope-specific options the caller reads through qm_api_opt.
# Scope names are [A-Za-z0-9_], 1-32 chars; anything else fails closed.
# Current scopes: metrics (metrics/prometheus.sh).
#
# Contract
# --------
# qm_api_auth <scope> [https]
#     With "https", plain-HTTP requests are denied too (use it for any scope
#     that acts rather than reads). Call before anything forks (sourcing this
#     lib forks nothing). Moves
#     HTTP_AUTHORIZATION into a local and unsets it, reads the scope with one
#     `uci -q show quecmanager.<scope>` fork, accepts only
#     "Bearer <64 lowercase hex>" (scheme word "Bearer" or "bearer"), and
#     always runs exactly one qm_timing_safe_compare (against fixed dummies
#     when the scope is disabled, has no valid token, or the presentation is
#     malformed). Setup-required (no password yet) also denies.
#     Success: returns 0 with QM_API_SCOPE=<scope> and QM_API_CFG set (the
#     scope's uci lines minus the token line). A uci read with any line that
#     is not the scope's own (a value carrying a newline) denies.
#     Failure: writes the uniform 403 (qm_api_deny) and EXITS the script.
#     The 403 is identical for every reason, so a probe can't tell whether
#     the scope is enabled. A failure on an enabled scope is logged at most
#     once per 60 s per scope (REMOTE_ADDR only) via the uptime stamp
#     /var/run/qmanager/api_authfail_<scope>.stamp.
#
# qm_api_opt <option>
#     After a successful qm_api_auth: sets QM_API_VAL to the scope option's
#     value from the same uci read (empty when absent). Never returns the
#     token (QM_API_VAL is empty for "token"). Values are uci-quoted text up to
#     the first ', so callers must enumerate / validate what they get.
#
# qm_api_deny
#     Prints the uniform 403 (Status, Content-Type, Cache-Control, blank line,
#     "Forbidden"). Callers that must fail closed without this lib print the
#     same bytes.
#
# qm_api_token_generate <scope>
#     Generates a token (qm_generate_token), validates it, and writes
#     `set quecmanager.<scope>=<scope>` + the token with `uci batch` on stdin,
#     then commits. Never echoes, logs or argv's the token.
#     Returns 0 ok, 1 invalid scope, 2 generation failed, 3 write/commit failed.
#     To enable a scope safely: generate the token FIRST, then set enabled=1,
#     so a scrape never sees enabled=1 without a valid token.
#
# Never log, echo or put on argv the Authorization header or any token.

[ -n "$_QM_API_AUTH_LOADED" ] && return 0
_QM_API_AUTH_LOADED=1

# Guarded: a `.` on a missing file aborts BusyBox ash. Missing helpers make
# qm_api_auth deny (fail closed), never allow.
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh
[ -f /usr/lib/qmanager/cgi_auth.sh ] && . /usr/lib/qmanager/cgi_auth.sh
[ -f /usr/lib/qmanager/qlog.sh ] && . /usr/lib/qmanager/qlog.sh

QM_API_SCOPE=""
QM_API_CFG=""
QM_API_VAL=""
QM_API_AUTHFAIL_INTERVAL=60
QM_API_RUN_DIR="/var/run/qmanager"

qm_api_deny() {
    echo "Status: 403 Forbidden"
    echo "Content-Type: text/plain; charset=utf-8"
    echo "Cache-Control: no-store"
    echo ""
    echo "Forbidden"
}

# 0 when $1 is a usable scope name.
_qm_api_scope_ok() {
    case "$1" in
        ''|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    [ "${#1}" -le 32 ]
}

# 0 when $1 is exactly 64 lowercase hex.
_qm_api_token_ok() {
    case "$1" in
        ''|*[!0-9a-f]*) return 1 ;;
    esac
    [ "${#1}" -eq 64 ]
}

# _qm_api_get <scope> <option> — QM_API_VAL from QM_API_CFG.
_qm_api_get() {
    QM_API_VAL=""
    case "$QM_API_CFG" in
        *"
quecmanager.$1.$2='"*)
            QM_API_VAL="${QM_API_CFG#*
quecmanager.$1.$2=\'}"
            QM_API_VAL="${QM_API_VAL%%\'*}"
            ;;
    esac
}

# _qm_api_line_closed <line> — 0 when every quoted value on a `uci show` line
# closes on that line. uci prints a value as '...' with an embedded ' as '\'';
# with those escapes removed a complete line holds an even number of quotes,
# and a value that carries a newline leaves its first line odd.
_qm_api_line_closed() {
    local s
    local q
    s="$1"
    while :; do
        case "$s" in
            *"'\\''"*) s="${s%%"'\\''"*}${s#*"'\\''"}" ;;
            *) break ;;
        esac
    done
    q=0
    while :; do
        case "$s" in
            *"'"*) s="${s#*\'}"; q=$((q + 1)) ;;
            *) break ;;
        esac
    done
    [ $((q % 2)) -eq 0 ]
}

# _qm_api_sanitize <scope> — 1 when the read is not a clean set of the scope's
# own one-line options: a foreign line, or a value spanning lines (which could
# otherwise inject a line that shadows enabled/token for _qm_api_get's first
# match). On 0 it also drops the token line, so the stored token does not
# outlive the compare in a shell variable. Builtins only (heredoc + read).
_qm_api_sanitize() {
    local line
    local out
    out=""
    while IFS= read -r line; do
        case "$line" in
            '') continue ;;
            "quecmanager.$1="*|"quecmanager.$1."*)
                _qm_api_line_closed "$line" || { QM_API_CFG=""; return 1; } ;;
            *) QM_API_CFG=""; return 1 ;;
        esac
        case "$line" in
            "quecmanager.$1."token=*) continue ;;
        esac
        out="$out
$line"
    done <<EOF
$QM_API_CFG
EOF
    QM_API_CFG="$out"
    return 0
}

qm_api_opt() {
    QM_API_VAL=""
    [ -n "$QM_API_SCOPE" ] || return 1
    case "$1" in
        token|''|*[!A-Za-z0-9_]*) return 1 ;;
    esac
    _qm_api_get "$QM_API_SCOPE" "$1"
}

# Uptime-stamped, per-scope rate limit; the stamp lives in the root-only run
# dir (/var/run is root 0755, so nobody else can plant it or its entries).
_qm_api_log_fail() {
    local scope
    local up
    local rest
    local last
    local addr
    local stamp
    scope="$1"
    up=""
    last=""
    command -v qlog_warn >/dev/null 2>&1 || return 0
    { read -r up rest < /proc/uptime; } 2>/dev/null
    up="${up%%.*}"
    case "$up" in ''|*[!0-9]*|0?*|???????????*) return 0 ;; esac
    if [ ! -d "$QM_API_RUN_DIR" ] || [ -L "$QM_API_RUN_DIR" ]; then
        command -v qm_run_dir >/dev/null 2>&1 || return 0
        qm_run_dir >/dev/null 2>&1 || return 0
    fi
    stamp="$QM_API_RUN_DIR/api_authfail_${scope}.stamp"
    { read -r last rest < "$stamp"; } 2>/dev/null
    case "$last" in ''|*[!0-9]*|0?*|???????????*) last="" ;; esac
    if [ -n "$last" ] && [ "$last" -le "$up" ] \
       && [ $((up - last)) -lt "$QM_API_AUTHFAIL_INTERVAL" ]; then
        return 0
    fi
    { printf '%s\n' "$up" > "$stamp.$$" && mv -f "$stamp.$$" "$stamp"; } 2>/dev/null \
        || { rm -f "$stamp.$$" 2>/dev/null; return 0; }
    addr="$REMOTE_ADDR"
    case "$addr" in ''|*[!0-9A-Fa-f.:]*) addr="unknown" ;; esac
    qlog_init "api_auth"
    qlog_warn "$scope API request rejected (from $addr; further rejections muted for ${QM_API_AUTHFAIL_INTERVAL}s)"
}

qm_api_auth() {
    local hdr
    local scope
    local ok
    local enabled
    local given
    local stored

    # Out of the environment before the first fork (uci, awk).
    hdr="$HTTP_AUTHORIZATION"
    unset HTTP_AUTHORIZATION

    scope="$1"
    ok=1
    QM_API_SCOPE=""
    QM_API_CFG=""
    if _qm_api_scope_ok "$scope"; then
        QM_API_CFG="
$(uci -q show "quecmanager.$scope" 2>/dev/null)"
    else
        scope="invalid"
        ok=0
    fi

    _qm_api_get "$scope" enabled
    enabled="$QM_API_VAL"
    _qm_api_get "$scope" token
    stored="$QM_API_VAL"
    QM_API_VAL=""
    # A multi-line value voids the whole read (fail closed); the token line is
    # dropped from QM_API_CFG either way.
    _qm_api_sanitize "$scope" || { ok=0; enabled=""; stored=""; }
    [ "$enabled" = "1" ] || ok=0
    # Opt-in for scopes that act (e.g. a future send API): the bearer must not
    # cross the LAN in cleartext.
    # Any other non-empty mode (a typo like "HTTPS") fails closed rather than
    # silently dropping the TLS requirement.
    case "$2" in
        '') ;;
        https) [ "$HTTPS" = "on" ] || ok=0 ;;
        *) ok=0 ;;
    esac
    if command -v is_setup_required >/dev/null 2>&1; then
        is_setup_required && ok=0
    else
        ok=0
    fi

    given=""
    case "$hdr" in
        "Bearer "*|"bearer "*) given="${hdr#* }" ;;
    esac
    hdr=""

    # The two dummies differ, so a disabled scope can never match a
    # malformed presentation.
    if ! _qm_api_token_ok "$given"; then
        given="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        ok=0
    fi
    if ! _qm_api_token_ok "$stored"; then
        stored="0000000000000000000000000000000000000000000000000000000000000000"
        ok=0
    fi

    if command -v qm_timing_safe_compare >/dev/null 2>&1; then
        qm_timing_safe_compare "$given" "$stored" || ok=0
    else
        ok=0
    fi
    given=""
    stored=""

    if [ "$ok" != "1" ]; then
        QM_API_CFG=""
        qm_api_deny
        [ "$enabled" = "1" ] && _qm_api_log_fail "$scope"
        exit 0
    fi
    QM_API_SCOPE="$scope"
    return 0
}

qm_api_token_generate() {
    local scope
    local tok
    scope="$1"
    _qm_api_scope_ok "$scope" || return 1
    command -v qm_generate_token >/dev/null 2>&1 || return 2
    tok=$(qm_generate_token)
    if ! _qm_api_token_ok "$tok"; then
        tok=""
        return 2
    fi
    # printf is a builtin: the token reaches uci on stdin, never on argv.
    if ! printf 'set quecmanager.%s=%s\nset quecmanager.%s.token=%s\n' \
            "$scope" "$scope" "$scope" "$tok" | uci batch >/dev/null 2>&1; then
        tok=""
        return 3
    fi
    tok=""
    uci commit quecmanager >/dev/null 2>&1 || return 3
    return 0
}
