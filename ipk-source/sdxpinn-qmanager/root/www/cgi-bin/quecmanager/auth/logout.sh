#!/bin/sh
# logout.sh — Destroy session and clear cookies.
_SKIP_AUTH=1
. /usr/lib/qmanager/cgi_base.sh

qlog_init "cgi_auth_logout"

if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
    cgi_headers
    exit 0
fi

if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_headers
    cgi_method_not_allowed
fi

_token=$(qm_get_cookie "$COOKIE_SESSION")
if [ -n "$_token" ]; then
    qm_destroy_session "$_token"
    qlog_info "Session destroyed via logout"
fi

qm_clear_session_cookies
cgi_headers
cgi_success
