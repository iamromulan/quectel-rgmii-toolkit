#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# send_command.sh — CGI Endpoint for AT Terminal Commands
# =============================================================================
# Accepts a user's AT command, passes it through qcmd, and returns the
# raw modem response as JSON.
#
# Endpoint: POST /cgi-bin/quecmanager/at_cmd/send_command.sh
# Request body: {"command": "AT+COPS?"}
# Response: {"success": true, "response": "...", "command": "AT+COPS?"}
#
# Install location: /www/cgi-bin/quecmanager/at_cmd/send_command.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_terminal"
cgi_headers
cgi_handle_options

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Read POST body ----------------------------------------------------------
cgi_read_post

# --- Extract command from JSON ------------------------------------------------
COMMAND=$(printf '%s' "$POST_DATA" | jq -r '.command // empty')

if [ -z "$COMMAND" ]; then
    qlog_warn "Terminal request with missing command field"
    cgi_error "no_command" "Missing command field in JSON body"
    exit 0
fi

qlog_info "Terminal command: ${COMMAND}"

# --- Reject anything that isn't an AT command ---------------------------------
# The modem never answers a line that doesn't start with AT, so sending one
# would hold the modem for the full deadline and block every other caller.
# qcmd refuses it too (invalid_command); this gives the terminal a plain reason.
case "$COMMAND" in
    [Aa][Tt]*) ;;
    *)
        qlog_warn "Terminal rejected non-AT input"
        cgi_error "invalid_command" "Only AT commands can be sent here. Start the line with AT, for example AT+CSQ."
        exit 0
        ;;
esac

# --- Safety check: Block long commands from the raw terminal ------------------
case "$COMMAND" in
    *QSCAN*|*QSCANFREQ*)
        qlog_warn "Terminal blocked long command: ${COMMAND}"
        cgi_error "blocked" "Use the Cell Scanner page for this command."
        exit 0
        ;;
esac

# --- Execute via qcmd ---------------------------------------------------------
RESULT=$(qcmd -j "$COMMAND")

echo "$RESULT"
