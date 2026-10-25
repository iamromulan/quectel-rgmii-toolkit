#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# ttl.sh — CGI Endpoint: TTL / Hop Limit Configuration (GET + POST)
# =============================================================================
# GET:  Reads current TTL and HL values from the firewall rules file.
# POST: Applies new TTL/HL via iptables/ip6tables and persists to file.
#
# Files:
#   /etc/firewall.user.ttl          — Persistent firewall rules (iptables cmds)
#   /etc/init.d/quecmanager_ttl     — Boot persistence init script
#
# POST body: { "ttl": 64, "hl": 64 }
#   - ttl: 0-255  (0 = disable / use default)
#   - hl:  0-255  (0 = disable / use default)
#
# This endpoint is the standalone TTL/HL manager. The same firewall rules
# file is shared with the Custom SIM Profile apply script
# (qmanager_profile_apply), so both paths write the same canonical format.
#
# Endpoint: GET/POST /cgi-bin/quecmanager/network/ttl.sh
# Install location: /www/cgi-bin/quecmanager/network/ttl.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_ttl"
cgi_headers
cgi_handle_options

# --- Configuration -----------------------------------------------------------
TTL_FILE="/etc/firewall.user.ttl"
TTL_INIT="/etc/init.d/qmanager_ttl"

# --- Helper: parse current values from the firewall rules file ----------------
get_current_values() {
    local ttl=0 hl=0
    if [ -s "$TTL_FILE" ]; then
        ttl=$(grep 'iptables.*--ttl-set' "$TTL_FILE" 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++){if($i=="--ttl-set"){print $(i+1)}}}' \
            | head -1)
        hl=$(grep 'ip6tables.*--hl-set' "$TTL_FILE" 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++){if($i=="--hl-set"){print $(i+1)}}}' \
            | head -1)
    fi
    [ -z "$ttl" ] && ttl=0
    [ -z "$hl" ] && hl=0
    echo "$ttl $hl"
}

# =============================================================================
# GET — Read current TTL/HL configuration
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Reading TTL/HL configuration"

    # Parse current values
    read cur_ttl cur_hl <<EOF
$(get_current_values)
EOF

    # Determine enabled status
    is_enabled="false"
    if [ "$cur_ttl" -gt 0 ] 2>/dev/null || [ "$cur_hl" -gt 0 ] 2>/dev/null; then
        is_enabled="true"
    fi

    # Check autostart status
    autostart="false"
    if [ -f "$TTL_INIT" ] && "$TTL_INIT" enabled 2>/dev/null; then
        autostart="true"
    fi

    qlog_info "Current: TTL=$cur_ttl HL=$cur_hl enabled=$is_enabled autostart=$autostart"

    jq -n \
        --argjson is_enabled "$is_enabled" \
        --argjson ttl "$cur_ttl" \
        --argjson hl "$cur_hl" \
        --argjson autostart "$autostart" \
        '{
            success: true,
            is_enabled: $is_enabled,
            ttl: $ttl,
            hl: $hl,
            autostart: $autostart
        }'
    exit 0
fi

# =============================================================================
# POST — Apply TTL/HL configuration
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    new_ttl=$(printf '%s' "$POST_DATA" | jq -r '.ttl // "0"')
    new_hl=$(printf '%s' "$POST_DATA" | jq -r '.hl // "0"')

    # --- Validate TTL ---
    case "$new_ttl" in
        ''|*[!0-9]*)
            cgi_error "invalid_ttl" "TTL must be a number between 0 and 255"
            exit 0
            ;;
    esac
    if [ "$new_ttl" -gt 255 ] 2>/dev/null; then
        cgi_error "invalid_ttl" "TTL must be between 0 and 255"
        exit 0
    fi

    # --- Validate HL ---
    case "$new_hl" in
        ''|*[!0-9]*)
            cgi_error "invalid_hl" "HL must be a number between 0 and 255"
            exit 0
            ;;
    esac
    if [ "$new_hl" -gt 255 ] 2>/dev/null; then
        cgi_error "invalid_hl" "HL must be between 0 and 255"
        exit 0
    fi

    qlog_info "Applying TTL=$new_ttl HL=$new_hl"

    # --- Clear existing iptables rules ---
    read cur_ttl cur_hl <<EOF
$(get_current_values)
EOF

    if [ "$cur_ttl" -gt 0 ] 2>/dev/null; then
        iptables -t mangle -D POSTROUTING -o rmnet+ -j TTL --ttl-set "$cur_ttl" 2>/dev/null
    fi
    if [ "$cur_hl" -gt 0 ] 2>/dev/null; then
        ip6tables -t mangle -D POSTROUTING -o rmnet+ -j HL --hl-set "$cur_hl" 2>/dev/null
    fi

    # --- Write new rules file (atomic: temp + mv) ---
    TTL_TMP="${TTL_FILE}.tmp"
    > "$TTL_TMP"
    if [ "$new_ttl" -gt 0 ] 2>/dev/null; then
        echo "iptables -t mangle -A POSTROUTING -o rmnet+ -j TTL --ttl-set $new_ttl" >> "$TTL_TMP"
        iptables -t mangle -A POSTROUTING -o rmnet+ -j TTL --ttl-set "$new_ttl"
    fi
    if [ "$new_hl" -gt 0 ] 2>/dev/null; then
        echo "ip6tables -t mangle -A POSTROUTING -o rmnet+ -j HL --hl-set $new_hl" >> "$TTL_TMP"
        ip6tables -t mangle -A POSTROUTING -o rmnet+ -j HL --hl-set "$new_hl"
    fi
    # sync around the rename: on UBIFS a rename can reach flash before the
    # data and leave an empty rules file after a power cut.
    sync
    mv "$TTL_TMP" "$TTL_FILE"
    sync

    # Determine new enabled state
    is_enabled="false"
    if [ "$new_ttl" -gt 0 ] 2>/dev/null || [ "$new_hl" -gt 0 ] 2>/dev/null; then
        is_enabled="true"
    fi

    qlog_info "TTL/HL applied: TTL=$new_ttl HL=$new_hl enabled=$is_enabled"

    jq -n \
        --argjson is_enabled "$is_enabled" \
        --argjson ttl "$new_ttl" \
        --argjson hl "$new_hl" \
        '{
            success: true,
            is_enabled: $is_enabled,
            ttl: $ttl,
            hl: $hl
        }'
    exit 0
fi

# --- Method not allowed -------------------------------------------------------
cgi_method_not_allowed
