#!/bin/sh
# =============================================================================
# apply_cancel.sh — Signal the restore worker to cancel after current section
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/cgi_auth.sh

cgi_require_auth

if [ "$REQUEST_METHOD" != "POST" ]; then
    printf 'Status: 405\r\nContent-Type: application/json\r\nAllow: POST\r\n\r\n'
    echo '{"error":"method_not_allowed"}'
    exit 0
fi

touch /tmp/qmanager_config_restore.cancel

printf 'Status: 200\r\nContent-Type: application/json\r\n\r\n'
echo '{"status":"cancel_requested"}'
