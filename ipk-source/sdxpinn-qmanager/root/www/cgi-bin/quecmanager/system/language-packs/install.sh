#!/bin/sh
# =============================================================================
# install.sh — POST: start language-pack install
# =============================================================================
# Body: { "code": "fr", "manifest_url": "https://..." }
# Limits: 4 KiB body cap.
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/language_packs.sh

qlog_init "lp_install_cgi"

MAX_BODY_SIZE=$((4 * 1024))
WORKER="/usr/bin/qmanager_language_install"

if [ "$REQUEST_METHOD" != "POST" ]; then
    printf 'Status: 405\r\nContent-Type: application/json\r\nAllow: POST\r\n\r\n'
    echo '{"error":"method_not_allowed"}'
    exit 0
fi

case "$CONTENT_TYPE" in
    application/json*|'') ;;
    *)
        printf 'Status: 415\r\nContent-Type: application/json\r\n\r\n'
        echo '{"error":"unsupported_content_type"}'
        exit 0
        ;;
esac

if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt "$MAX_BODY_SIZE" ] 2>/dev/null; then
    printf 'Status: 413\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"payload_too_large"}'
    exit 0
fi

# Concurrency guard
if [ -f "$LP_PID_FILE" ]; then
    _existing=$(cat "$LP_PID_FILE" 2>/dev/null)
    if [ -n "$_existing" ] && kill -0 "$_existing" 2>/dev/null; then
        printf 'Status: 409\r\nContent-Type: application/json\r\n\r\n'
        echo "{\"error\":\"install_in_progress\",\"pid\":${_existing}}"
        exit 0
    fi
fi

# Read body
BODY=$(dd bs="$CONTENT_LENGTH" count=1 2>/dev/null)

echo "$BODY" | jq -e '.' >/dev/null 2>&1 || {
    printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"invalid_json"}'
    exit 0
}

CODE=$(echo "$BODY" | jq -r '.code // empty')
MANIFEST_URL=$(echo "$BODY" | jq -r '.manifest_url // empty')

[ -z "$CODE" ] && {
    printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"missing_code"}'
    exit 0
}

lp_pack_is_code_safe "$CODE" || {
    printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"invalid_code"}'
    exit 0
}

[ -z "$MANIFEST_URL" ] && {
    printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"missing_manifest_url"}'
    exit 0
}

# Persist input + clear stale progress
echo "$BODY" | qm_atomic_write "$LP_INPUT_FILE" 0600
rm -f "$LP_CANCEL_FILE" "$LP_PROGRESS_FILE"

# Emit pending progress so the client's first poll doesn't race the worker.
lp_write_progress "running" "$CODE" 0 "start" "Starting install..."

# Send response BEFORE spawning worker (firewall-restart-kills-HTTP memory).
printf 'Status: 202\r\nContent-Type: application/json\r\n\r\n'
echo "{\"ok\":true,\"state\":\"running\",\"code\":\"$CODE\"}"

# Double-fork detached worker
( "$WORKER" </dev/null >/dev/null 2>&1 & )

exit 0
