#!/bin/sh
# CGI base library — HTTP headers, POST parsing, JSON response helpers.
# Source this at the top of every CGI script instead of copy-pasting boilerplate.
#
# Usage:
#   . /usr/lib/qmanager/cgi_base.sh
#   qlog_init "cgi_myname"
#   cgi_headers
#   cgi_handle_options   # call only on scripts that accept POST

[ -n "$_CGI_BASE_LOADED" ] && return 0
_CGI_BASE_LOADED=1

# ---------------------------------------------------------------------------
# Logging — source qlog.sh with no-op fallbacks if library is missing
# ---------------------------------------------------------------------------
# GUARD with [ -f ] before dot-sourcing: a `.` on a MISSING file aborts a
# non-interactive BusyBox ash script (POSIX special builtin), so the `|| {...}`
# stub fallback would never run. Guard, then define stubs in the else branch.
if [ -f /usr/lib/qmanager/qlog.sh ]; then
    . /usr/lib/qmanager/qlog.sh
else
    qlog_init()  { :; }
    qlog_debug() { :; }
    qlog_info()  { :; }
    qlog_warn()  { :; }
    qlog_error() { :; }
    record_planned_reboot() { :; }
fi

# ---------------------------------------------------------------------------
# Authentication — source cgi_auth.sh with fail-closed fallbacks if missing
# ---------------------------------------------------------------------------
[ -f /usr/lib/qmanager/cgi_auth.sh ] && . /usr/lib/qmanager/cgi_auth.sh
# require_auth is the library's last function, so an empty or truncated file
# (e.g. zeroed by power loss after an unsynced deploy) sources cleanly but
# leaves it undefined. Treat that exactly like a missing library.
if ! type require_auth >/dev/null 2>&1; then
    # Fails closed on purpose: a missing auth library must never become a bypass.
    require_auth() {
        echo "Status: 500 Internal Server Error"
        cgi_headers
        printf '%s\n' '{"success":false,"error":"internal_error","detail":"auth library unavailable"}'
        exit 0
    }
    is_setup_required()     { return 1; }
    qm_get_cookie()         { :; }
    qm_set_session_cookies(){ :; }
    qm_clear_session_cookies(){ :; }
    qm_create_session()     { :; }
    qm_validate_session()   { return 1; }
    qm_destroy_session()    { :; }
    qm_cleanup_sessions()   { :; }
    qm_verify_password()    { return 1; }
    qm_save_password()      { return 1; }
    qm_check_rate_limit()   { return 0; }
    qm_get_rate_limit_status() { RATE_LIMIT_RETRY_AFTER=0; RATE_LIMIT_ATTEMPTS_REMAINING=5; return 0; }
    qm_record_failed_attempt() { :; }
    qm_clear_attempts()     { :; }
fi

# ---------------------------------------------------------------------------
# HTTP Headers
# Emit full JSON + CORS headers followed by the required blank line.
# Call once, before writing any response body.
# ---------------------------------------------------------------------------
cgi_headers() {
    echo "Content-Type: application/json"
    echo "Cache-Control: no-cache, no-store, must-revalidate"
    echo "Access-Control-Allow-Origin: *"
    echo "Access-Control-Allow-Methods: GET, POST, OPTIONS"
    echo "Access-Control-Allow-Headers: Content-Type, Authorization"
    echo ""
}

# ---------------------------------------------------------------------------
# Auto-enforce auth unless the calling script set _SKIP_AUTH=1.
#
# MUST stay below cgi_headers(): require_auth() calls cgi_headers on its 401
# reject path, and POSIX sourcing runs top-to-bottom. If this block runs
# before cgi_headers is defined, the reject emits no blank-line header
# terminator, so uhttpd returns 502 instead of 401 — which silently breaks
# the frontend's "401 -> redirect to login" recovery (e.g. after a reboot
# wipes /tmp sessions, every auth-gated endpoint would 502 forever).
#
# This still runs during the source, before the calling script's own
# post-source code, so unauthenticated requests are rejected before any
# handler executes.
# ---------------------------------------------------------------------------
if [ "$_SKIP_AUTH" != "1" ]; then
    require_auth
fi

# ---------------------------------------------------------------------------
# CORS Preflight
# Call right after cgi_headers on scripts that accept POST.
# Exits 0 immediately for OPTIONS requests (browser pre-flight).
# ---------------------------------------------------------------------------
cgi_handle_options() {
    [ "$REQUEST_METHOD" = "OPTIONS" ] && exit 0
}

# ---------------------------------------------------------------------------
# POST Body Reader
# Reads stdin into POST_DATA using CONTENT_LENGTH.
# Exits with a JSON error response if the body is missing or empty.
# ---------------------------------------------------------------------------
cgi_read_post() {
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        POST_DATA=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    else
        cgi_error "no_body" "POST body is empty"
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Method Routing Fallback
# Call at the bottom of the method routing block.
# Returns 405 JSON and exits for any unsupported HTTP method.
# ---------------------------------------------------------------------------
cgi_method_not_allowed() {
    jq -n '{"success":false,"error":"method_not_allowed","detail":"Use GET or POST"}'
    exit 0
}

# ---------------------------------------------------------------------------
# JSON Response Helpers
# ---------------------------------------------------------------------------

# Emit {"success":true}
cgi_success() {
    jq -n '{"success":true}'
}

# cgi_error <error_code> <detail_message>
cgi_error() {
    jq -n --arg error "$1" --arg detail "${2:-}" \
        '{"success":false,"error":$error,"detail":$detail}'
}

# ---------------------------------------------------------------------------
# Reboot After Response
# Emit success JSON, then schedule an async reboot so the HTTP response
# flushes to the client before the device goes down.
#
# $1 — optional reboot reason tag for the persistent ledger (default "user").
# record_planned_reboot runs SYNCHRONOUSLY here, before the backgrounded reboot,
# so the breadcrumb is durable on ubifs by the time the kernel goes down and the
# next boot classifies this as a planned user reboot (not an unplanned loss).
# ---------------------------------------------------------------------------
cgi_reboot_response() {
    record_planned_reboot "${1:-user}"
    echo '{"success":true}'
    ( ( sleep 1; sync; reboot ) </dev/null >/dev/null 2>&1 & )
    exit 0
}

# ---------------------------------------------------------------------------
# NDJSON File Server
# Serve an NDJSON file (one JSON object per line) as a JSON array.
# Outputs "[]" if file doesn't exist or is empty.
#
# Usage:
#   serve_ndjson_as_array "/tmp/myfile.json"
# ---------------------------------------------------------------------------
serve_ndjson_as_array() {
    if [ -f "$1" ] && [ -s "$1" ]; then
        jq -s '.' "$1"
    else
        echo "[]"
    fi
}
