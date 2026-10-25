#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# apply_status.sh — CGI Endpoint: Profile Apply Status
# =============================================================================
# Returns the current state of a profile application in progress.
# Reads directly from /tmp/qmanager_profile_state.json (written by the
# apply script). Zero modem interaction.
#
# Also detects if the apply process has died unexpectedly (PID gone but
# status still "applying") and corrects the state.
#
# Endpoint: GET /cgi-bin/quecmanager/profiles/apply_status.sh
# Response: Contents of /tmp/qmanager_profile_state.json
#       or: {"status":"idle"} if no apply has been run
#
# Install location: /www/cgi-bin/quecmanager/profiles/apply_status.sh
# =============================================================================

# --- Configuration -----------------------------------------------------------
STATE_FILE="/tmp/qmanager_profile_state.json"
PID_FILE="/tmp/qmanager_profile_apply.pid"

qlog_init "cgi_apply_status"
cgi_headers
cgi_handle_options

# --- Case 1: No state file — nothing has been applied yet --------------------
if [ ! -f "$STATE_FILE" ]; then
    jq -n '{"status":"idle"}'
    exit 0
fi

# --- Case 2: State file exists — return it -----------------------------------
# But first, check for orphaned "applying" state (process died mid-apply).
STATE_STATUS=$(jq -r '.status // empty' "$STATE_FILE" 2>/dev/null)

if [ "$STATE_STATUS" = "applying" ]; then
    # Verify the apply process is still alive
    if [ -f "$PID_FILE" ]; then
        APPLY_PID=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$APPLY_PID" ] && ! kill -0 "$APPLY_PID" 2>/dev/null; then
            # Process died but state says "applying" — correct to "failed"
            tmp=$(jq '.status = "failed"' "$STATE_FILE" 2>/dev/null) && {
                # B4.1: mktemp sibling instead of a fixed .tmp name
                _st_tmp=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null)
                printf '%s\n' "$tmp" > "$_st_tmp" && mv -f "$_st_tmp" "$STATE_FILE" || rm -f "$_st_tmp"
            }
            rm -f "$PID_FILE"
        fi
    else
        # No PID file but state says "applying" — process exited and cleaned up
        # but never wrote a final state. Mark as failed.
        tmp=$(jq '.status = "failed"' "$STATE_FILE" 2>/dev/null) && {
            _st_tmp=$(mktemp "${STATE_FILE}.XXXXXX" 2>/dev/null)
            printf '%s\n' "$tmp" > "$_st_tmp" && mv -f "$_st_tmp" "$STATE_FILE" || rm -f "$_st_tmp"
        }
    fi
fi

cat "$STATE_FILE"
