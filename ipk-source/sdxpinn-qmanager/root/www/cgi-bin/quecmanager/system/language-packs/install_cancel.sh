#!/bin/sh
# =============================================================================
# install_cancel.sh — POST: signal worker to cancel between steps
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/language_packs.sh

if [ "$REQUEST_METHOD" != "POST" ]; then
    printf 'Status: 405\r\nContent-Type: application/json\r\nAllow: POST\r\n\r\n'
    echo '{"error":"method_not_allowed"}'
    exit 0
fi

touch "$LP_CANCEL_FILE"

cgi_headers
cgi_success
