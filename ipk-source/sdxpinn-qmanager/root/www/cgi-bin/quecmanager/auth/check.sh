#!/bin/sh
# check.sh — Auth status check (used by login page for setup detection).
_SKIP_AUTH=1
. /usr/lib/qmanager/cgi_base.sh

qlog_init "cgi_auth_check"
cgi_headers

if is_setup_required; then
    jq -n '{"authenticated":false,"setup_required":true}'
    exit 0
fi

_token=$(qm_get_cookie "$COOKIE_SESSION")
if [ -n "$_token" ] && qm_validate_session "$_token"; then
    jq -n '{"authenticated":true}'
    exit 0
fi

# Lets the login page disable its button during a lockout instead of
# offering a submit that would just 429. Must stay on the READ-ONLY
# qm_get_rate_limit_status: qm_check_rate_limit mutates the attempts file,
# so a refresh during a lockout would engage or extend it.
if qm_get_rate_limit_status; then
    _rate_limited="false"
else
    _rate_limited="true"
fi

jq -n --argjson limited "$_rate_limited" \
    --argjson retry "${RATE_LIMIT_RETRY_AFTER:-0}" \
    --argjson remaining "${RATE_LIMIT_ATTEMPTS_REMAINING:-0}" \
    '{"authenticated":false,"rate_limited":$limited,"retry_after":$retry,"attempts_remaining":$remaining}'
