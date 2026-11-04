#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# storage.sh — CGI Endpoint: user storage usage (GET)
# =============================================================================
# df of /usrdata, the one writable UBIFS volume (it also backs /, /etc, /data
# and /persist through the overlay). One df per request; the dashboard polls
# every 30 s. No poller involvement (ledger B5.22, U4.22).
#
# GET → {"success":true,"storage":{"mount":"/usrdata","total_kb":N,
#        "used_kb":N,"available_kb":N}}   storage:null when df fails.
#
# Endpoint: GET /cgi-bin/quecmanager/system/storage.sh
# Install location: /www/cgi-bin/quecmanager/system/storage.sh
# =============================================================================

qlog_init "cgi_storage"
cgi_headers
cgi_handle_options

MOUNT="/usrdata"

if [ "$REQUEST_METHOD" != "GET" ]; then
    cgi_method_not_allowed
    exit 0
fi

# Line 2 of `df -P`: fs, 1024-blocks, used, available, capacity, mount.
line=""
df_out=$(df -P "$MOUNT" 2>/dev/null)
nl='
'
rest="${df_out#*$nl}"
[ "$rest" != "$df_out" ] && line="${rest%%$nl*}"

total=""
used=""
avail=""
if [ -n "$line" ]; then
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    total="${2:-}"
    used="${3:-}"
    avail="${4:-}"
fi

ok=1
for v in "$total" "$used" "$avail"; do
    case "$v" in ''|*[!0-9]*) ok=0 ;; esac
done
[ "$ok" = "1" ] && [ "$total" -gt 0 ] || ok=0

if [ "$ok" = "1" ]; then
    jq -n --arg m "$MOUNT" --argjson t "$total" --argjson u "$used" --argjson a "$avail" \
        '{success:true, storage:{mount:$m, total_kb:$t, used_kb:$u, available_kb:$a}}'
else
    qlog_warn "df $MOUNT unreadable"
    jq -n '{success:true, storage:null}'
fi
