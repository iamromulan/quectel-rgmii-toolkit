#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/cgi_at.sh
. /usr/lib/qmanager/sim_db.sh
# =============================================================================
# known_sims.sh — CGI Endpoint: Known-SIMs Database (GET + POST)
# =============================================================================
# The known-SIMs database is a persistent set of ICCIDs the device has already
# "seen". qmanager_poller fires the "New SIM detected" banner exactly when the
# inserted SIM's ICCID is NOT in this set (see sim_db.sh).
#
# GET (or POST {"action":"list"}):
#   Returns {"success":true,"count":<N>} where N = number of known ICCIDs.
#
# POST {"action":"clear"}:
#   Resets the set to contain ONLY the currently-inserted SIM (read live via
#   AT+QCCID). The inserted SIM stays known so clearing does not immediately
#   re-fire the banner. If no SIM is present, the set is emptied. Also drops
#   any stale /tmp/qmanager_sim_swap_detected banner flag.
#   Returns {"success":true,"count":<N>}.
#
# Endpoint: GET/POST /cgi-bin/quecmanager/system/known_sims.sh
# Install location: /www/cgi-bin/quecmanager/system/known_sims.sh
# =============================================================================

qlog_init "cgi_known_sims"
cgi_headers
cgi_handle_options

SIM_SWAP_FLAG="/tmp/qmanager_sim_swap_detected"

# =============================================================================
# GET — Report the known-SIMs count
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    count=$(sim_db_count)
    jq -n --argjson count "$count" '{success: true, count: $count}'
    exit 0
fi

# =============================================================================
# POST — Actions (list, clear)
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post

    action=$(printf '%s' "$POST_DATA" | jq -r 'if .action == null then empty else .action end')

    case "$action" in
        list)
            count=$(sim_db_count)
            jq -n --argjson count "$count" '{success: true, count: $count}'
            ;;
        clear)
            qlog_info "Clearing known-SIMs set (keeping currently-inserted SIM)"
            # Canonical QCCID pipeline — byte-identical to all other read sites.
            # A transport failure must not read as "no SIM inserted": that clears
            # the inserted SIM too. A modem ERROR (no SIM seated) clears all.
            at_exec 'AT+QCCID'
            if [ $? -eq 1 ]; then
                cgi_error "modem_error" "Could not read the inserted SIM; nothing was cleared"
                exit 0
            fi
            cur=$(printf '%s\n' "$AT_RAW" | grep '+QCCID:' | sed 's/+QCCID: //g' | tr -d '\r ')
            sim_db_clear_keep "$cur"
            rm -f "$SIM_SWAP_FLAG"
            count=$(sim_db_count)
            qlog_info "Known-SIMs set cleared; count now $count"
            jq -n --argjson count "$count" '{success: true, count: $count}'
            ;;
        *)
            cgi_error "invalid_action" "Action must be: list or clear"
            ;;
    esac
    exit 0
fi

# --- Method not allowed -------------------------------------------------------
cgi_method_not_allowed
