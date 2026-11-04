#!/bin/sh
# =============================================================================
# apply_status.sh — Returns the current restore progress file
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/cgi_auth.sh

cgi_require_auth

STATE_FILE="/tmp/qmanager_config_restore.json"

printf 'Status: 200\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
else
    echo '{"status":"idle"}'
fi
