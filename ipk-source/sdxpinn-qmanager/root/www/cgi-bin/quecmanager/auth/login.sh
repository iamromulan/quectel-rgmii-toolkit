#!/bin/sh
# login.sh — Login and first-time password setup endpoint.
# POST {"password":"..."} for login
# POST {"password":"...","confirm":"..."} for first-time setup
#
# On success, sets HttpOnly session cookie + indicator cookie.
_SKIP_AUTH=1
. /usr/lib/qmanager/cgi_base.sh

qlog_init "cgi_auth_login"

# CORS preflight
if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
    cgi_headers
    exit 0
fi

if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_headers
    cgi_method_not_allowed
fi

# Read POST body inline (to defer headers for 429 status)
if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
    POST_DATA=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
else
    cgi_headers
    cgi_error "no_body" "POST body is empty"
    exit 0
fi

_password=$(printf '%s' "$POST_DATA" | jq -r '.password // empty')
_confirm=$(printf '%s' "$POST_DATA" | jq -r '.confirm // empty')
_enforce_strong=$(printf '%s' "$POST_DATA" | jq -r 'if .enforce_strong == false then "false" else "true" end')

if [ -z "$_password" ]; then
    cgi_headers
    cgi_error "missing_password" "Password is required"
    exit 0
fi

# ---------------------------------------------------------------------------
# First-time setup mode
# ---------------------------------------------------------------------------
if is_setup_required; then
    if [ -z "$_confirm" ]; then
        cgi_headers
        jq -n '{"success":false,"error":"setup_required","setup_required":true}'
        exit 0
    fi

    # Validation rules (must match frontend and auth/password.sh exactly):
    #   - length >= 5
    #   - If strong password enforced: at least one uppercase, lowercase, digit
    _pw_len=$(printf '%s' "$_password" | wc -c)
    if [ "$_enforce_strong" = "false" ]; then
        if [ "$_pw_len" -lt 5 ]; then
            cgi_headers
            cgi_error "password_weak" "Password must be at least 5 characters"
            exit 0
        fi
    else
        if [ "$_pw_len" -lt 5 ] \
           || ! printf '%s' "$_password" | grep -q '[A-Z]' \
           || ! printf '%s' "$_password" | grep -q '[a-z]' \
           || ! printf '%s' "$_password" | grep -q '[0-9]'; then
            cgi_headers
            cgi_error "password_weak" "Password must be at least 5 characters and include uppercase, lowercase, and a number"
            exit 0
        fi
    fi

    if [ "$_password" != "$_confirm" ]; then
        cgi_headers
        cgi_error "password_mismatch" "Passwords do not match"
        exit 0
    fi

    if ! qm_save_password "$_password"; then
        qlog_error "First-time password could not be saved"
        cgi_headers
        cgi_error "write_failed" "Could not save the password"
        exit 0
    fi
    qlog_info "First-time password configured"

    _token=$(qm_create_session)
    if [ -z "$_token" ]; then
        cgi_error "session_failed" "Could not create a session"
        exit 0
    fi
    qm_set_session_cookies "$_token"
    cgi_headers
    jq -n '{"success":true}'
    exit 0
fi

# ---------------------------------------------------------------------------
# Normal login
# ---------------------------------------------------------------------------
if ! qm_check_rate_limit; then
    echo "Status: 429 Too Many Requests"
    cgi_headers
    jq -n --argjson retry "${RATE_LIMIT_RETRY_AFTER:-0}" \
        --argjson remaining "${RATE_LIMIT_ATTEMPTS_REMAINING:-0}" \
        '{"success":false,"error":"rate_limited","detail":"Too many failed attempts","retry_after":$retry,"attempts_remaining":$remaining}'
    exit 0
fi

if ! qm_verify_password "$_password"; then
    qm_record_failed_attempt
    # Read-only re-check so the response reports what remains after this
    # failure. A failure at ladder level >= 1 has just re-locked, so this
    # reads 0; the next request gets the 429 with retry_after.
    qm_get_rate_limit_status
    qlog_warn "Failed login attempt"
    cgi_headers
    jq -n --argjson remaining "${RATE_LIMIT_ATTEMPTS_REMAINING:-0}" \
        '{"success":false,"error":"invalid_password","detail":"Invalid password","attempts_remaining":$remaining}'
    exit 0
fi

# Success
qm_clear_attempts
qm_cleanup_sessions
_token=$(qm_create_session)
if [ -z "$_token" ]; then
    qlog_error "Login: session directory is not root-owned; refusing to create a session"
    cgi_error "session_failed" "Could not create a session"
    exit 0
fi
qlog_info "Successful login"

qm_set_session_cookies "$_token"
cgi_headers
jq -n '{"success":true}'
