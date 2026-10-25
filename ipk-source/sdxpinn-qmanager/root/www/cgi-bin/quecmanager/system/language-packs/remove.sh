#!/bin/sh
# =============================================================================
# remove.sh — POST: delete /www/locales/<code>/
# =============================================================================
# Body: { "code": "fr" }
# Refuses if code is bundled (en or zh-CN) or unsafe.
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/language_packs.sh

qlog_init "lp_remove_cgi"

MAX_BODY_SIZE=$((4 * 1024))

# Bundled codes cannot be removed.
LP_BUNDLED_CODES="en zh-CN"

if [ "$REQUEST_METHOD" != "POST" ]; then
    printf 'Status: 405\r\nContent-Type: application/json\r\nAllow: POST\r\n\r\n'
    echo '{"error":"method_not_allowed"}'
    exit 0
fi

if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt "$MAX_BODY_SIZE" ] 2>/dev/null; then
    printf 'Status: 413\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"payload_too_large"}'
    exit 0
fi

BODY=$(dd bs="$CONTENT_LENGTH" count=1 2>/dev/null)

echo "$BODY" | jq -e '.' >/dev/null 2>&1 || {
    printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"invalid_json"}'
    exit 0
}

CODE=$(echo "$BODY" | jq -r '.code // empty')

[ -z "$CODE" ] && {
    printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"missing_code"}'
    exit 0
}

# Reject bundled codes.
for _b in $LP_BUNDLED_CODES; do
    if [ "$CODE" = "$_b" ]; then
        printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
        echo '{"error":"cannot_remove_bundled"}'
        exit 0
    fi
done

lp_pack_is_code_safe "$CODE" || {
    printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"invalid_code"}'
    exit 0
}

if ! lp_remove_pack "$CODE"; then
    printf 'Status: 500\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"remove_failed"}'
    exit 0
fi

cgi_headers
cgi_success
