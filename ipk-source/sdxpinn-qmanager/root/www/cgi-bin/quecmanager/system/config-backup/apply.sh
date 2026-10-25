#!/bin/sh
# =============================================================================
# apply.sh — Accept decrypted payload, spawn config restore worker
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/cgi_auth.sh
. /usr/lib/qmanager/config_backup_sections.sh
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

cgi_require_auth

if [ "$REQUEST_METHOD" != "POST" ]; then
    printf 'Status: 405\r\nContent-Type: application/json\r\nAllow: POST\r\n\r\n'
    echo '{"error":"method_not_allowed"}'
    exit 0
fi

MAX_BODY_SIZE=$((256 * 1024))
PID_FILE="/var/run/qmanager_config_restore.pid"
INPUT_FILE="/tmp/qmanager_config_restore_input.json"
APPLY_BIN="/usr/bin/qmanager_config_restore"

# --- Content-Type check ---
case "$CONTENT_TYPE" in
    application/json*|'') ;;
    *)
        printf 'Status: 415\r\nContent-Type: application/json\r\n\r\n'
        echo '{"error":"unsupported_content_type"}'
        exit 0
        ;;
esac

# --- Size check ---
if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt "$MAX_BODY_SIZE" ] 2>/dev/null; then
    printf 'Status: 413\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"payload_too_large"}'
    exit 0
fi

# --- Concurrency guard ---
if [ -f "$PID_FILE" ]; then
    existing=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
        printf 'Status: 409\r\nContent-Type: application/json\r\n\r\n'
        echo "{\"error\":\"restore_in_progress\",\"pid\":${existing}}"
        exit 0
    fi
fi

# --- Read body ---
BODY=$(dd bs="$CONTENT_LENGTH" count=1 2>/dev/null)

# --- Parse validation ---
if ! echo "$BODY" | jq -e '.' >/dev/null 2>&1; then
    printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"invalid_json"}'
    exit 0
fi

schema=$(echo "$BODY" | jq -r '.schema // empty')
if [ "$schema" != "1" ]; then
    printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"wrong_schema"}'
    exit 0
fi

# Validate each section key is known
keys=$(echo "$BODY" | jq -r '.sections | keys[]' 2>/dev/null)
for k in $keys; do
    if ! cfg_backup_is_known_section "$k"; then
        printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
        echo "{\"error\":\"unknown_section\",\"key\":\"$k\"}"
        exit 0
    fi
done

if [ -z "$keys" ]; then
    printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"no_sections"}'
    exit 0
fi

# --- Persist payload + clear stale state ---
# B4.1: root-owned 0600 payload; a planted file at the fixed name is replaced, not written through
if ! echo "$BODY" | qm_atomic_write "$INPUT_FILE" 0600; then
    printf 'Status: 500\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"persist_failed"}'
    exit 0
fi
rm -f /tmp/qmanager_config_restore.cancel /tmp/qmanager_config_restore.json

JOB_ID=$(date +%s)

# --- Double-fork detached spawn ---
( "$APPLY_BIN" "$JOB_ID" </dev/null >/dev/null 2>&1 & )

printf 'Status: 202\r\nContent-Type: application/json\r\n\r\n'
echo "{\"status\":\"started\",\"job_id\":\"$JOB_ID\"}"
