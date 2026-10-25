#!/bin/sh
# cgi_auth.sh — Cookie-based authentication library for QManager CGI scripts.
# Sourced by cgi_base.sh. Provides require_auth() and password helpers.
#
# Storage:
#   /etc/qmanager/auth.json              — password hash + salt (persistent)
#   /tmp/qmanager_sessions/<token>        — one file per session (RAM, cleared on reboot)
#   /tmp/qmanager_auth_attempts.json      — rate limiting state (RAM)
#   /tmp/qmanager_auth_attempts.lock      — flock target serializing RMW on the above
#
# Attempts file shape (every field defaulted on read, so a file written by the
# pre-ladder flat limiter, which had no "level"/"last_failure", reads sanely):
#   {"count":N,"first_attempt":EPOCH,"locked_until":EPOCH,
#    "level":0-4,"last_failure":EPOCH}

[ -n "$_CGI_AUTH_LOADED" ] && return 0
_CGI_AUTH_LOADED=1

[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

AUTH_CONFIG="/etc/qmanager/auth.json"
SESSIONS_DIR="/tmp/qmanager_sessions"
ATTEMPTS_FILE="/tmp/qmanager_auth_attempts.json"
ATTEMPTS_LOCK="/tmp/qmanager_auth_attempts.lock"

SESSION_MAX_AGE=3600  # 1 hour

# Cookie names
COOKIE_SESSION="qm_session"
COOKIE_INDICATOR="qm_logged_in"

# Rate limiting
MAX_ATTEMPTS=5
LOCKOUT_WINDOW=300              # 5-minute window for counting pre-ladder attempts
LOCKOUT_STEPS="30 120 300 900"  # progressive lockout ladder, seconds; last = cap
LEVEL_DECAY=3600                # quiet seconds after which the ladder level resets to 0

# ---------------------------------------------------------------------------
# Setup check
# ---------------------------------------------------------------------------
is_setup_required() {
    [ ! -f "$AUTH_CONFIG" ] && return 0
    [ ! -s "$AUTH_CONFIG" ] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Password hashing
# ---------------------------------------------------------------------------

qm_generate_salt() {
    head -c 16 /dev/urandom | openssl dgst -sha256 -hex 2>/dev/null | awk '{print substr($NF,1,32)}'
}

qm_hash_password() {
    printf '%s' "${2}${1}" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}'
}

# Timing-safe string comparison via awk
qm_timing_safe_compare() {
    _result=$(printf '%s\n%s' "$1" "$2" | awk '
        NR==1 { a=$0 }
        NR==2 {
            b=$0
            len = length(a)
            if (length(b) > len) len = length(b)
            diff = (length(a) != length(b))
            for (i=1; i<=len; i++)
                if (substr(a,i,1) != substr(b,i,1)) diff=1
            print diff
        }')
    [ "$_result" = "0" ]
}

qm_verify_password() {
    _input_password="$1"
    [ ! -f "$AUTH_CONFIG" ] && return 1

    _auth_fields=$(jq -r '[.salt // "", .hash // ""] | @tsv' "$AUTH_CONFIG" 2>/dev/null)
    _stored_salt=$(printf '%s' "$_auth_fields" | cut -f1)
    _stored_hash=$(printf '%s' "$_auth_fields" | cut -f2)

    [ -z "$_stored_salt" ] && return 1
    [ -z "$_stored_hash" ] && return 1

    _computed_hash=$(qm_hash_password "$_input_password" "$_stored_salt")
    qm_timing_safe_compare "$_computed_hash" "$_stored_hash"
}

qm_save_password() {
    _new_salt=$(qm_generate_salt)
    _new_hash=$(qm_hash_password "$1" "$_new_salt")
    # An empty salt or hash (openssl failed) would lock everyone out: the file
    # is non-empty, so setup is not offered, and no password ever verifies.
    [ -n "$_new_salt" ] && [ -n "$_new_hash" ] || return 1
    command -v qm_durable_write >/dev/null 2>&1 || return 1

    _auth_json=$(jq -n --arg hash "$_new_hash" --arg salt "$_new_salt" \
        '{"hash":$hash,"salt":$salt,"version":1}') || return 1
    [ -n "$_auth_json" ] || return 1
    # Replace, never truncate: a crash mid-write keeps the old password.
    printf '%s\n' "$_auth_json" | qm_durable_write "$AUTH_CONFIG" 0600
}

# ---------------------------------------------------------------------------
# Cookie helpers
# ---------------------------------------------------------------------------

# Extract a named cookie value from HTTP_COOKIE
# Usage: _cookie_val=$(qm_get_cookie "cookie_name")
qm_get_cookie() {
    _cookie_name="$1"
    # HTTP_COOKIE format: "name1=val1; name2=val2"
    printf '%s' "$HTTP_COOKIE" | awk -v name="$_cookie_name" '
    BEGIN { RS=";[ \t]*"; FS="=" }
    $1 == name { print $2; exit }
    '
}

# Emit Set-Cookie headers for both session and indicator cookies
# Usage: qm_set_session_cookies <token>
qm_set_session_cookies() {
    echo "Set-Cookie: ${COOKIE_SESSION}=${1}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${SESSION_MAX_AGE}"
    echo "Set-Cookie: ${COOKIE_INDICATOR}=1; SameSite=Strict; Path=/; Max-Age=${SESSION_MAX_AGE}"
}

# Emit Set-Cookie headers that clear both cookies
qm_clear_session_cookies() {
    echo "Set-Cookie: ${COOKIE_SESSION}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"
    echo "Set-Cookie: ${COOKIE_INDICATOR}=; SameSite=Strict; Path=/; Max-Age=0"
}

# ---------------------------------------------------------------------------
# Session management (directory-based, one file per session)
# ---------------------------------------------------------------------------

qm_generate_token() {
    head -c 32 /dev/urandom | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}'
}

# Validate token is safe for use as a filename (hex chars only)
_is_valid_token() {
    printf '%s' "$1" | grep -qE '^[0-9a-f]{64}$'
}

# Create a new session. Prints the token to stdout.
qm_create_session() {
    # B4.1: the dir is absent after every boot; one another user made first
    # would let them mint sessions, so it must be root's own.
    command -v qm_root_dir >/dev/null 2>&1 || return 1
    qm_root_dir "$SESSIONS_DIR" 0700 || return 1
    _token=$(qm_generate_token)
    date +%s > "${SESSIONS_DIR}/${_token}"
    printf '%s' "$_token"
}

# Validate a session token: check file exists and not expired.
# Returns 0 if valid, 1 if invalid/expired.
qm_validate_session() {
    _check_token="$1"
    [ -z "$_check_token" ] && return 1
    _is_valid_token "$_check_token" || return 1

    _session_file="${SESSIONS_DIR}/${_check_token}"
    [ ! -f "$_session_file" ] && return 1
    command -v qm_owned_by_root >/dev/null 2>&1 || return 1
    qm_owned_by_root "$SESSIONS_DIR" || return 1
    qm_owned_by_root "$_session_file" || return 1

    _created=$(cat "$_session_file" 2>/dev/null)
    # Reject empty or non-numeric content. A bare epoch timestamp is the only
    # valid session-file body; anything else (e.g. a stale pre-2026-03-17
    # JSON session blob) would crash the $(( )) arithmetic below under ash.
    case "$_created" in
        ''|*[!0-9]*) rm -f "$_session_file"; return 1 ;;
    esac

    _now=$(date +%s)
    _age=$(( _now - _created ))
    [ "$_age" -gt "$SESSION_MAX_AGE" ] && {
        rm -f "$_session_file"
        return 1
    }

    return 0
}

# Destroy a specific session
qm_destroy_session() {
    _token="$1"
    [ -z "$_token" ] && return
    _is_valid_token "$_token" || return
    rm -f "${SESSIONS_DIR}/${_token}"
}

# Clean up expired sessions (called on login)
qm_cleanup_sessions() {
    [ ! -d "$SESSIONS_DIR" ] && return
    _now=$(date +%s)
    for _f in "${SESSIONS_DIR}"/*; do
        [ ! -f "$_f" ] && continue
        _created=$(cat "$_f" 2>/dev/null)
        # Evict any file whose body is empty or non-numeric. Feeding a
        # non-integer into $(( )) is a FATAL ash error that would abort the
        # caller (login) mid-flow — a single malformed/stale file must not
        # be able to take down the whole login path.
        case "$_created" in
            ''|*[!0-9]*) rm -f "$_f"; continue ;;
        esac
        _age=$(( _now - _created ))
        [ "$_age" -gt "$SESSION_MAX_AGE" ] && rm -f "$_f"
    done
}

# ---------------------------------------------------------------------------
# Rate limiting
# ---------------------------------------------------------------------------

#
# Progressive lockout ladder:
#   failures 1..5 (level 0)  -> allowed, RATE_LIMIT_ATTEMPTS_REMAINING counts 4..0
#   6th request              -> locked  30s before the password check (level 1)
#   next failure             -> locked 120s (level 2)
#   next failure             -> locked 300s (level 3)
#   next failure             -> locked 900s (level 4 = cap, stays here)
#   successful login         -> qm_clear_attempts deletes the file, level -> 0
#   LEVEL_DECAY (1h) quiet   -> level decays back to 0 on next read
#
# Once the ladder is engaged (level >= 1) a SINGLE failure re-locks at the
# next rung; count only gates the first level 0 -> 1 transition.
#
# qm_get_rate_limit_status() is the READ-ONLY half, safe for the
# unauthenticated status probe (auth/check.sh) because it never mutates
# ATTEMPTS_FILE, so page refreshes cannot extend a lockout.
# qm_check_rate_limit() is the login-path half: the same read plus the
# level 0 -> 1 engage. qm_record_failed_attempt() does the level >= 1
# escalate. Both mutations run under ATTEMPTS_LOCK.
#
# Lock acquisition is best-effort: if ATTEMPTS_LOCK is still held after the
# poll budget, the write proceeds unlocked. Losing one counted attempt to a
# race beats a login endpoint that hangs or 500s.

# _qm_rl_int <value> — print <value> if it is a non-negative integer, else 0.
# Guards every stored field before $(( )): a non-integer there is a FATAL
# ash error that would abort the login CGI mid-flow.
_qm_rl_int() {
    case "$1" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$1" ;;
    esac
}

# _qm_lockout_seconds <level> — seconds for ladder level N (1-based), clamped
# to the last LOCKOUT_STEPS entry for any level beyond the ladder's length.
_qm_lockout_seconds() {
    _qm_ls_lvl=$(_qm_rl_int "$1")
    [ "$_qm_ls_lvl" -lt 1 ] && _qm_ls_lvl=1
    _qm_ls_n=0
    _qm_ls_val=0
    for _qm_ls_s in $LOCKOUT_STEPS; do
        _qm_ls_n=$(( _qm_ls_n + 1 ))
        _qm_ls_val="$_qm_ls_s"
        [ "$_qm_ls_n" -ge "$_qm_ls_lvl" ] && break
    done
    printf '%s' "$_qm_ls_val"
}

# _qm_lockout_step_count — number of rungs in LOCKOUT_STEPS, so the stored
# "level" never grows unbounded across repeated re-lockouts.
_qm_lockout_step_count() {
    _qm_lsc_n=0
    for _qm_lsc_s in $LOCKOUT_STEPS; do
        _qm_lsc_n=$(( _qm_lsc_n + 1 ))
    done
    printf '%s' "$_qm_lsc_n"
}

# _qm_rate_limit_read_state — read ATTEMPTS_FILE in one jq pass, default and
# integer-guard every field, apply level decay, and expose the result via
# _RL_COUNT _RL_FIRST _RL_LOCKED_UNTIL _RL_LEVEL _RL_LAST_FAILURE.
# Never mutates the file.
_qm_rate_limit_read_state() {
    _RL_COUNT=0
    _RL_FIRST=0
    _RL_LOCKED_UNTIL=0
    _RL_LEVEL=0
    _RL_LAST_FAILURE=0

    [ ! -f "$ATTEMPTS_FILE" ] && return 0

    _rl_fields=$(jq -r '[(.count // 0), (.first_attempt // 0), (.locked_until // 0), (.level // 0), (.last_failure // 0)] | @tsv' "$ATTEMPTS_FILE" 2>/dev/null)
    _RL_COUNT=$(_qm_rl_int "$(printf '%s' "$_rl_fields" | cut -f1)")
    _RL_FIRST=$(_qm_rl_int "$(printf '%s' "$_rl_fields" | cut -f2)")
    _RL_LOCKED_UNTIL=$(_qm_rl_int "$(printf '%s' "$_rl_fields" | cut -f3)")
    _RL_LEVEL=$(_qm_rl_int "$(printf '%s' "$_rl_fields" | cut -f4)")
    _RL_LAST_FAILURE=$(_qm_rl_int "$(printf '%s' "$_rl_fields" | cut -f5)")

    _rl_now=$(date +%s)
    if [ "$_RL_LAST_FAILURE" -gt 0 ]; then
        _rl_quiet=$(( _rl_now - _RL_LAST_FAILURE ))
        [ "$_rl_quiet" -gt "$LEVEL_DECAY" ] && _RL_LEVEL=0
    fi
}

# _qm_rate_limit_remaining — MAX_ATTEMPTS minus the current count, clamped
# to [0, MAX_ATTEMPTS]. Assumes _qm_rate_limit_read_state has just run.
_qm_rate_limit_remaining() {
    _rl_remaining=$(( MAX_ATTEMPTS - _RL_COUNT ))
    [ "$_rl_remaining" -lt 0 ] && _rl_remaining=0
    [ "$_rl_remaining" -gt "$MAX_ATTEMPTS" ] && _rl_remaining=$MAX_ATTEMPTS
    printf '%s' "$_rl_remaining"
}

# qm_attempts_flock_wait <fd> <timeout_seconds>
# BusyBox flock has no -w/--timeout, so poll `flock -x -n` at qcmd's 0.1s
# grain with the same total budget. Returns 0 = acquired, 1 = timed out;
# callers proceed either way (best-effort, see above).
qm_attempts_flock_wait() {
    _qm_fw_fd="$1"
    _qm_fw_iters=$(( $2 * 10 ))
    _qm_fw_i=0
    while [ "$_qm_fw_i" -lt "$_qm_fw_iters" ]; do
        flock -x -n "$_qm_fw_fd" 2>/dev/null && return 0
        sleep 0.1
        _qm_fw_i=$(( _qm_fw_i + 1 ))
    done
    flock -x -n "$_qm_fw_fd" 2>/dev/null
}

# _qm_engage_lockout <level> — write a fresh lockout at the given ladder level
# (clamped): locked_until = now + step(level), last_failure = now,
# count/first_attempt carried over. Call with ATTEMPTS_LOCK held.
_qm_engage_lockout() {
    _qm_el_lvl=$(_qm_rl_int "$1")
    _qm_el_cap=$(_qm_lockout_step_count)
    [ "$_qm_el_lvl" -gt "$_qm_el_cap" ] && _qm_el_lvl=$_qm_el_cap

    _qm_rate_limit_read_state
    _qm_el_now=$(date +%s)
    _qm_el_seconds=$(_qm_lockout_seconds "$_qm_el_lvl")

    jq -n --argjson count "$_RL_COUNT" --argjson first "$_RL_FIRST" \
        --argjson locked "$(( _qm_el_now + _qm_el_seconds ))" \
        --argjson level "$_qm_el_lvl" --argjson lastf "$_qm_el_now" \
        '{"count":$count,"first_attempt":$first,"locked_until":$locked,"level":$level,"last_failure":$lastf}' \
        > "${ATTEMPTS_FILE}.tmp" 2>/dev/null \
        && mv "${ATTEMPTS_FILE}.tmp" "$ATTEMPTS_FILE"
}

# qm_get_rate_limit_status — READ-ONLY. Sets RATE_LIMIT_RETRY_AFTER and
# RATE_LIMIT_ATTEMPTS_REMAINING. Returns 0 (not locked) or 1 (locked).
qm_get_rate_limit_status() {
    RATE_LIMIT_RETRY_AFTER=0
    RATE_LIMIT_ATTEMPTS_REMAINING=$MAX_ATTEMPTS

    [ ! -f "$ATTEMPTS_FILE" ] && return 0

    _qm_rate_limit_read_state
    _qm_grl_now=$(date +%s)

    if [ "$_RL_LOCKED_UNTIL" -gt "$_qm_grl_now" ]; then
        RATE_LIMIT_RETRY_AFTER=$(( _RL_LOCKED_UNTIL - _qm_grl_now ))
        RATE_LIMIT_ATTEMPTS_REMAINING=0
        return 1
    fi

    RATE_LIMIT_ATTEMPTS_REMAINING=$(_qm_rate_limit_remaining)
    return 0
}

# qm_check_rate_limit — login-path gate, called before qm_verify_password.
# Same read as qm_get_rate_limit_status, plus: reset an expired level-0
# counting window, and engage the level 0 -> 1 lockout the first time count
# reaches MAX_ATTEMPTS. Sets the same two RATE_LIMIT_* globals.
qm_check_rate_limit() {
    qm_get_rate_limit_status || return 1

    [ ! -f "$ATTEMPTS_FILE" ] && return 0

    _qm_rate_limit_read_state
    _qm_crl_now=$(date +%s)

    # Pre-ladder counting window fully expired with no lock ever engaged.
    _qm_crl_window_age=$(( _qm_crl_now - _RL_FIRST ))
    if [ "$_RL_LEVEL" -eq 0 ] && [ "$_RL_FIRST" -gt 0 ] \
        && [ "$_qm_crl_window_age" -gt "$LOCKOUT_WINDOW" ]; then
        rm -f "$ATTEMPTS_FILE"
        RATE_LIMIT_ATTEMPTS_REMAINING=$MAX_ATTEMPTS
        return 0
    fi

    # First-time ladder trigger: MAX_ATTEMPTS reached, never locked before.
    if [ "$_RL_LEVEL" -eq 0 ] && [ "$_RL_COUNT" -ge "$MAX_ATTEMPTS" ]; then
        # 9>> creates the lock file on first use (uhttpd runs CGI as root).
        (
            qm_attempts_flock_wait 9 3
            _qm_engage_lockout 1
        ) 9>>"$ATTEMPTS_LOCK"

        _qm_rate_limit_read_state
        _qm_crl_now=$(date +%s)
        if [ "$_RL_LOCKED_UNTIL" -gt "$_qm_crl_now" ]; then
            RATE_LIMIT_RETRY_AFTER=$(( _RL_LOCKED_UNTIL - _qm_crl_now ))
        else
            # Engage write failed (e.g. /tmp full): still refuse this request.
            RATE_LIMIT_RETRY_AFTER=$(_qm_lockout_seconds 1)
        fi
        RATE_LIMIT_ATTEMPTS_REMAINING=0
        return 1
    fi

    return 0
}

# qm_record_failed_attempt — call after a failed qm_verify_password. Under
# ATTEMPTS_LOCK: bumps count (resetting an expired level-0 window), and if
# the ladder is already engaged (level >= 1), escalates one rung and re-locks.
qm_record_failed_attempt() {
    (
        qm_attempts_flock_wait 9 3
        _qm_record_failed_attempt_locked
    ) 9>>"$ATTEMPTS_LOCK"
}

# Internal — assumes fd 9 is flock'd (or the acquire timed out; best-effort).
_qm_record_failed_attempt_locked() {
    _qm_rfa_now=$(date +%s)

    if [ ! -f "$ATTEMPTS_FILE" ]; then
        jq -n --argjson now "$_qm_rfa_now" \
            '{"count":1,"first_attempt":$now,"locked_until":0,"level":0,"last_failure":$now}' \
            > "${ATTEMPTS_FILE}.tmp" 2>/dev/null && mv "${ATTEMPTS_FILE}.tmp" "$ATTEMPTS_FILE"
        return 0
    fi

    _qm_rate_limit_read_state
    _qm_rfa_count="$_RL_COUNT"
    _qm_rfa_first="$_RL_FIRST"
    _qm_rfa_level="$_RL_LEVEL"

    if [ "$_qm_rfa_level" -eq 0 ]; then
        _qm_rfa_window_age=$(( _qm_rfa_now - _qm_rfa_first ))
        if [ "$_qm_rfa_first" -eq 0 ] || [ "$_qm_rfa_window_age" -gt "$LOCKOUT_WINDOW" ]; then
            _qm_rfa_count=0
            _qm_rfa_first=0
        fi
    fi

    [ "$_qm_rfa_first" -eq 0 ] && _qm_rfa_first=$_qm_rfa_now
    _qm_rfa_count=$(( _qm_rfa_count + 1 ))

    if [ "$_qm_rfa_level" -ge 1 ]; then
        _qm_rfa_new_level=$(( _qm_rfa_level + 1 ))
        _qm_rfa_cap=$(_qm_lockout_step_count)
        [ "$_qm_rfa_new_level" -gt "$_qm_rfa_cap" ] && _qm_rfa_new_level=$_qm_rfa_cap
        _qm_rfa_seconds=$(_qm_lockout_seconds "$_qm_rfa_new_level")

        jq -n --argjson count "$_qm_rfa_count" --argjson first "$_qm_rfa_first" \
            --argjson locked "$(( _qm_rfa_now + _qm_rfa_seconds ))" \
            --argjson level "$_qm_rfa_new_level" --argjson lastf "$_qm_rfa_now" \
            '{"count":$count,"first_attempt":$first,"locked_until":$locked,"level":$level,"last_failure":$lastf}' \
            > "${ATTEMPTS_FILE}.tmp" 2>/dev/null && mv "${ATTEMPTS_FILE}.tmp" "$ATTEMPTS_FILE"
    else
        jq -n --argjson count "$_qm_rfa_count" --argjson first "$_qm_rfa_first" \
            --argjson lastf "$_qm_rfa_now" \
            '{"count":$count,"first_attempt":$first,"locked_until":0,"level":0,"last_failure":$lastf}' \
            > "${ATTEMPTS_FILE}.tmp" 2>/dev/null && mv "${ATTEMPTS_FILE}.tmp" "$ATTEMPTS_FILE"
    fi
}

qm_clear_attempts() {
    rm -f "$ATTEMPTS_FILE" "${ATTEMPTS_FILE}.tmp"
}

# ---------------------------------------------------------------------------
# Auth enforcement — called by cgi_base.sh on every request
# ---------------------------------------------------------------------------

# Main auth gate — rejects unauthenticated requests
require_auth() {
    # Setup mode
    if is_setup_required; then
        echo "Status: 401 Unauthorized"
        cgi_headers
        jq -n '{"success":false,"error":"setup_required","detail":"No password configured"}'
        exit 0
    fi

    # CORS preflight passes without auth
    [ "$REQUEST_METHOD" = "OPTIONS" ] && return 0

    # Read session token from cookie
    _token=$(qm_get_cookie "$COOKIE_SESSION")
    if [ -z "$_token" ] || ! qm_validate_session "$_token"; then
        echo "Status: 401 Unauthorized"
        cgi_headers
        jq -n '{"success":false,"error":"unauthorized","detail":"Invalid or expired session"}'
        exit 0
    fi
}
