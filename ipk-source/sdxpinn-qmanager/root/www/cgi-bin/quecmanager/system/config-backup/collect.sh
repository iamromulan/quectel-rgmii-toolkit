#!/bin/sh
# =============================================================================
# collect.sh — Configuration Backup Collector CGI
# =============================================================================
# GET /cgi-bin/quecmanager/system/config-backup/collect.sh?sections=k1,k2
# Returns plaintext JSON of the selected sections + device metadata.
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/cgi_auth.sh
. /usr/lib/qmanager/config_backup_sections.sh
if [ -f /usr/lib/qmanager/events.sh ]; then
    . /usr/lib/qmanager/events.sh
else
    append_event() { :; }
fi
EVENTS_FILE="/tmp/qmanager_events.json"
MAX_EVENTS=50

cgi_require_auth

# Parse sections query param
SECTIONS_CSV=$(echo "$QUERY_STRING" | awk -F'&' '{for(i=1;i<=NF;i++) if($i ~ /^sections=/) {sub(/^sections=/,"",$i); print $i}}')
# URL-decode minimally (comma only)
SECTIONS_CSV=$(echo "$SECTIONS_CSV" | sed 's/%2[Cc]/,/g')

if [ -z "$SECTIONS_CSV" ]; then
    printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"no_sections_selected"}'
    exit 0
fi

# Validate each key
for k in $(echo "$SECTIONS_CSV" | tr ',' ' '); do
    if ! cfg_backup_is_known_section "$k"; then
        printf 'Status: 400\r\nContent-Type: application/json\r\n\r\n'
        echo "{\"error\":\"unknown_section\",\"key\":\"$k\"}"
        exit 0
    fi
done

# Device metadata from poller cache
STATUS_FILE="/tmp/qmanager_status.json"
MODEL=""; FIRMWARE=""; IMEI=""
if [ -f "$STATUS_FILE" ]; then
    MODEL=$(jq -r '.device.model // ""' "$STATUS_FILE")
    FIRMWARE=$(jq -r '.device.firmware // ""' "$STATUS_FILE")
    IMEI=$(jq -r '.device.imei // ""' "$STATUS_FILE")
fi
QMV=$(cat /etc/qmanager/VERSION 2>/dev/null || echo "unknown")
CREATED=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Build sections JSON object
SECTIONS_JSON="{"
SEP=""
COUNT=0
for k in $(echo "$SECTIONS_CSV" | tr ',' ' '); do
    frag=$(cfg_backup_collect "$k") || {
        printf 'Status: 500\r\nContent-Type: application/json\r\n\r\n'
        echo "{\"error\":\"collect_failed\",\"key\":\"$k\"}"
        exit 0
    }
    SECTIONS_JSON="${SECTIONS_JSON}${SEP}\"${k}\":${frag}"
    SEP=","
    COUNT=$((COUNT+1))
done
SECTIONS_JSON="${SECTIONS_JSON}}"

# Pre-flight: ensure assembled SECTIONS_JSON is valid JSON before committing 200 status
if ! echo "$SECTIONS_JSON" | jq -e '.' >/dev/null 2>&1; then
    printf 'Status: 500\r\nContent-Type: application/json\r\n\r\n'
    echo '{"error":"collect_fragment_invalid"}'
    exit 0
fi

# Emit event
append_event "config_backup_collected" "Configuration backup collected ($COUNT sections)" "info" 2>/dev/null

printf 'Status: 200\r\nContent-Type: application/json\r\n\r\n'
jq -n \
    --arg created "$CREATED" \
    --arg model "$MODEL" --arg fw "$FIRMWARE" --arg imei "$IMEI" --arg qmv "$QMV" \
    --arg sections_csv "$SECTIONS_CSV" \
    --argjson sections "$SECTIONS_JSON" \
    '{
        schema: 1,
        header: {
            magic: "QMBACKUP",
            version: 1,
            created_at: $created,
            device: {model: $model, firmware: $fw, imei: $imei, qmanager_version: $qmv},
            sections_included: ($sections_csv | split(","))
        },
        payload: {schema: 1, sections: $sections}
    }'
