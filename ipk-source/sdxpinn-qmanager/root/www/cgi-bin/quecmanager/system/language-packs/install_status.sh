#!/bin/sh
# =============================================================================
# install_status.sh — GET current install progress
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/language_packs.sh

printf 'Status: 200\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
if [ -f "$LP_PROGRESS_FILE" ]; then
    cat "$LP_PROGRESS_FILE"
else
    echo '{"state":"idle","code":"","progress":0,"message":""}'
fi
