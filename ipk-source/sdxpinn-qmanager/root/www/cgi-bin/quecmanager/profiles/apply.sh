#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# apply.sh — CGI Endpoint: Apply SIM Profile (Async)
# =============================================================================
# Spawns qmanager_profile_apply as a detached process and returns immediately.
# The frontend polls apply_status.sh for progress.
#
# Follows the same setsid detachment pattern as speedtest_start.sh.
#
# Endpoint: POST /cgi-bin/quecmanager/profiles/apply.sh
# Request body: {"id": "<profile_id>"}
# Response: {"success":true,"status":"applying"}
#       or: {"success":false,"error":"...","detail":"..."}
#
# Install location: /www/cgi-bin/quecmanager/profiles/apply.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_profile_apply"
cgi_headers
cgi_handle_options

# --- Source profile manager library (for profile_get validation) -------------
. /usr/lib/qmanager/profile_mgr.sh

# --- Configuration -----------------------------------------------------------
STATE_FILE="/tmp/qmanager_profile_state.json"
APPLY_BIN="/usr/bin/qmanager_profile_apply"

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Read POST body ----------------------------------------------------------
cgi_read_post

# --- Extract profile ID from JSON body ----------------------------------------
PROFILE_ID=$(printf '%s' "$POST_DATA" | jq -r '.id // empty')

if [ -z "$PROFILE_ID" ]; then
    cgi_error "no_id" "Missing id field in request body"
    exit 0
fi

# --- Sanitize ID (prevent path traversal) ------------------------------------
case "$PROFILE_ID" in
    p_[0-9]*_[0-9a-f]*)
        # Valid format
        ;;
    *)
        cgi_error "invalid_id" "Invalid profile ID format"
        exit 0
        ;;
esac

# --- Check: profile exists? --------------------------------------------------
if [ ! -f "$PROFILE_DIR/${PROFILE_ID}.json" ]; then
    cgi_error "not_found" "Profile not found"
    exit 0
fi

# --- Atomically acquire the spawn-lock to reject concurrent CGI POSTs --------
# Lock layering:
#   - $PROFILE_SPAWN_LOCK_FILE  — owned by us (the CGI). Rejects parallel POSTs.
#   - $PROFILE_APPLY_PID_FILE   — owned by the worker. Singleton enforcement.
# Two separate files because the worker's profile_acquire_lock does kill -0 on
# the PID file's owner; if we wrote our own PID there, the worker would see us
# (still alive while waiting for the worker to come up) and abort.
# See plan 2026-05-03.
if ! profile_acquire_spawn_lock; then
    qlog_warn "Spawn already in progress (PID: $_profile_spawn_lock_pid)"
    cgi_error "apply_in_progress" "A profile is already being applied"
    exit 0
fi
# Also reject if a worker is already running — the spawn-lock alone doesn't
# cover the case where a previous worker is mid-apply.
if ! profile_check_lock; then
    profile_release_spawn_lock
    qlog_warn "Worker already running (PID: $_profile_lock_pid)"
    cgi_error "apply_in_progress" "A profile is already being applied"
    exit 0
fi

# --- Check: USB mode compatible with Verizon profiles? -----------------------
_apply_mno=$(jq -r '.mno // empty' "$PROFILE_DIR/${PROFILE_ID}.json" 2>/dev/null)
if [ "$_apply_mno" = "Verizon" ] && ! usb_mode_supports_mpdn; then
    profile_release_spawn_lock
    cgi_error "usb_mode_incompatible_for_verizon" "Verizon profiles require USB mode ECM or RNDIS"
    exit 0
fi

# --- Check: apply binary exists? ---------------------------------------------
if [ ! -x "$APPLY_BIN" ]; then
    profile_release_spawn_lock
    qlog_error "Apply binary not found: $APPLY_BIN"
    cgi_error "not_installed" "Profile apply script not found"
    exit 0
fi

# --- Clear previous state file -----------------------------------------------
rm -f "$STATE_FILE"

# --- Spawn worker (it will create $PROFILE_APPLY_PID_FILE on startup) --------
qlog_info "Spawning profile apply for: $PROFILE_ID"

# Detach via subshell (pure POSIX, no setsid needed)
( "$APPLY_BIN" "$PROFILE_ID" </dev/null >/dev/null 2>&1 & )

# --- Wait for worker to come up (max ~2s, 100ms granularity) -----------------
# Success criterion: $PROFILE_APPLY_PID_FILE exists with a live PID that is
# NOT the CGI's own PID. (We never wrote our PID into that file under the new
# scheme, but the inequality check is cheap defense-in-depth.)
NEW_PID=""
i=0
while [ "$i" -lt 20 ]; do
    if [ -f "$PROFILE_APPLY_PID_FILE" ]; then
        NEW_PID=$(cat "$PROFILE_APPLY_PID_FILE" 2>/dev/null)
        if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$$" ] && kill -0 "$NEW_PID" 2>/dev/null; then
            break
        fi
        NEW_PID=""
    fi
    # BusyBox sleep accepts fractional seconds.
    sleep 0.1
    i=$((i + 1))
done

# --- Release spawn-lock unconditionally — the worker owns its own PID file ---
profile_release_spawn_lock

# --- Report outcome ----------------------------------------------------------
if [ -n "$NEW_PID" ]; then
    qlog_info "Profile apply started (PID: $NEW_PID)"
    jq -n --argjson pid "$NEW_PID" '{"success":true,"status":"applying","pid":$pid}'
else
    qlog_error "Apply process did not register within 2s"
    if [ -f "$STATE_FILE" ]; then
        # Worker started, wrote a state file, then exited (e.g. profile_get
        # returned empty). Surface the worker's own error to the frontend.
        cat "$STATE_FILE"
    else
        cgi_error "start_failed" "Apply process failed to start"
    fi
fi
