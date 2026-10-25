#!/bin/sh
# =============================================================================
# sim_db.sh — Known-SIMs database (shared library)
# =============================================================================
# Model
# -----
# QManager tracks a PERSISTENT SET of ICCIDs the device has already "seen"
# (the known-SIMs database). A SIM is "new" iff its ICCID is NOT a member of
# this set. On detection of a new SIM, its ICCID is added immediately so the
# "New SIM" banner fires exactly once.
#
# This replaces the older single-value /etc/qmanager/last_iccid scheme (which
# could only remember ONE prior SIM). sim_db_seed_if_absent() migrates that
# legacy file forward on first run.
#
# Storage
# -------
#   KNOWN_SIMS_FILE  — newline-delimited ICCIDs, one per line, no trailing
#                      whitespace per line. Lives under /etc/qmanager/ which is
#                      persistent (UBIFS, survives reboot).
#
# BYTE-PARITY REQUIREMENT
# -----------------------
# Membership is a whole-line fixed-string match (grep -qxF). The stored key
# MUST be byte-identical to the value the 5 existing QCCID read sites produce
# via the canonical pipeline:
#       grep '+QCCID:' | sed 's/+QCCID: //g' | tr -d '\r '
# i.e. a raw ~20-char string with NO trailing newline. sim_db_normalize()
# reproduces that normalization (strip space/CR/LF) so callers can pass either
# a pipeline result or a hand-built value and still match.
#
# Sourcing
# --------
# Sourced into poller, watchcat, profile_mgr, and the known_sims CGI. All
# internal variables are _simdb_-prefixed to avoid clobbering caller scope,
# and use one `local` per line (BusyBox-safe).
# =============================================================================

[ -n "$_SIM_DB_LOADED" ] && return 0
_SIM_DB_LOADED=1

KNOWN_SIMS_FILE="/etc/qmanager/known_iccids"
SIMDB_LEGACY_FILE="/etc/qmanager/last_iccid"

# sim_db_normalize <raw>
# Print the ICCID key with space/CR/LF stripped — matches the canonical
# pipeline's `tr -d '\r '` plus newline removal. No trailing newline emitted.
sim_db_normalize() {
    printf '%s' "$1" | tr -d ' \r\n'
}

# iccid_canonicalize <raw>
# COMPARE-TIME normalization only. Strips space/CR/LF (like sim_db_normalize),
# then strips a single trailing BCD pad nibble (F/f) if present. An ICCID whose
# final significant digit is odd is padded to 20 nibbles with a trailing F, and
# different read paths disagree on whether they keep it: apply-time readers keep
# the raw QCCID string (with F), while a digits-only extractor drops it. The
# real last character of an ICCID is always a decimal check digit, so a trailing
# F is always pad and safe to drop. Use this to normalize BOTH operands when
# COMPARING a live ICCID against a stored one — it does NOT change what the
# known-SIMs set stores (byte-parity there is preserved by sim_db_normalize).
iccid_canonicalize() {
    local _simdb_canon
    _simdb_canon=$(printf '%s' "$1" | tr -d ' \r\n')
    case "$_simdb_canon" in
        *[Ff]) _simdb_canon=${_simdb_canon%?} ;;
    esac
    printf '%s' "$_simdb_canon"
}

# sim_db_seed_if_absent
# Migration + first-run guard.
#   return 0 (prior knowledge existed) if KNOWN_SIMS_FILE already exists, OR
#            if it was just seeded from a non-empty legacy last_iccid.
#   return 1 (fresh device, no prior knowledge) if an empty set was created.
# The return code lets the poller suppress a spurious "new SIM" on a truly
# fresh device — it mirrors the old `[ -f last_iccid ]` guard.
sim_db_seed_if_absent() {
    if [ -f "$KNOWN_SIMS_FILE" ]; then
        return 0
    fi
    if [ -s "$SIMDB_LEGACY_FILE" ]; then
        local _simdb_legacy
        _simdb_legacy=$(sim_db_normalize "$(cat "$SIMDB_LEGACY_FILE" 2>/dev/null)")
        if [ -n "$_simdb_legacy" ]; then
            printf '%s\n' "$_simdb_legacy" > "$KNOWN_SIMS_FILE"
            return 0
        fi
    fi
    : > "$KNOWN_SIMS_FILE"
    return 1
}

# sim_db_known <iccid>
# Return 0 if the (normalized) ICCID is a member of the set, else 1.
# Empty input is never a member.
sim_db_known() {
    local _simdb_iccid
    _simdb_iccid=$(sim_db_normalize "$1")
    [ -z "$_simdb_iccid" ] && return 1
    grep -qxF "$_simdb_iccid" "$KNOWN_SIMS_FILE" 2>/dev/null
}

# sim_db_add <iccid>
# Add the (normalized) ICCID to the set if not already present. Idempotent.
# No-op on empty input. Check-before-append to minimize duplicate lines
# (membership is dup-tolerant; this is lock-free by design).
sim_db_add() {
    local _simdb_iccid
    _simdb_iccid=$(sim_db_normalize "$1")
    [ -z "$_simdb_iccid" ] && return 0
    if sim_db_known "$_simdb_iccid"; then
        return 0
    fi
    printf '%s\n' "$_simdb_iccid" >> "$KNOWN_SIMS_FILE"
}

# sim_db_clear_keep <iccid>
# Reset the set to contain ONLY the given (normalized) ICCID — used by the
# "clear known SIMs" action so the currently-inserted SIM stays known and
# does not re-fire the banner. Empty input truncates to an empty set.
sim_db_clear_keep() {
    local _simdb_iccid
    _simdb_iccid=$(sim_db_normalize "$1")
    if [ -n "$_simdb_iccid" ]; then
        printf '%s\n' "$_simdb_iccid" > "$KNOWN_SIMS_FILE"
    else
        : > "$KNOWN_SIMS_FILE"
    fi
}

# sim_db_count
# Print the number of known ICCIDs (non-empty lines) as a bare integer.
# Always prints a value (0 when the file is absent or empty).
sim_db_count() {
    local _simdb_n
    _simdb_n=0
    if [ -f "$KNOWN_SIMS_FILE" ]; then
        _simdb_n=$(grep -c . "$KNOWN_SIMS_FILE" 2>/dev/null)
    fi
    [ -z "$_simdb_n" ] && _simdb_n=0
    printf '%s' "$_simdb_n"
}
