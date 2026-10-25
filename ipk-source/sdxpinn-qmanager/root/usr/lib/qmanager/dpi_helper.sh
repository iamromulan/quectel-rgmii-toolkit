#!/bin/sh
# dpi_helper.sh — Video Optimizer (DPI evasion) shared functions
# Sourced by: qmanager_dpi (init.d), video_optimizer.sh (CGI), qmanager_dpi_verify

[ -n "$_DPI_HELPER_LOADED" ] && return 0
_DPI_HELPER_LOADED=1
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

NFQWS_BIN="/usr/bin/nfqws"
NFQWS_PID="/var/run/nfqws.pid"
DPI_HOSTLIST="/etc/qmanager/video_domains.txt"
DPI_HOSTLIST_DEFAULT="/etc/qmanager/video_domains_default.txt"
DPI_QUEUE_NUM=200
# Auto-detect cellular interface from default route, fallback to rmnet_data0
DPI_INTERFACE=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')
DPI_INTERFACE="${DPI_INTERFACE:-rmnet_data0}"
DPI_NFT_COMMENT="qmanager_dpi"

# Check if nfqws binary is installed and executable
dpi_check_binary() {
    [ -x "$NFQWS_BIN" ]
}

# Check if NFQUEUE kernel support is available (built-in or module)
dpi_check_kmod() {
    # Check if compiled into kernel (CONFIG_NETFILTER_NETLINK_QUEUE=y)
    if zcat /proc/config.gz 2>/dev/null | grep -q 'CONFIG_NETFILTER_NETLINK_QUEUE=y'; then
        return 0
    fi
    # Check if loaded as module
    if lsmod 2>/dev/null | grep -q nfnetlink_queue; then
        return 0
    fi
    # Try loading as module
    modprobe nfnetlink_queue 2>/dev/null || return 1
    return 0
}

# nftables rules are now shipped as a static /etc/nftables.d/12-mangle-qmanager-dpi.nft
# file (sourced by fw4 on every load/reload — survives `fw4 reload`). No runtime
# rule manipulation needed here. See that file for the rule definitions.

# Get service status: running, stopped, or error
dpi_get_status() {
    # B5.11: /var/run is root-only, but still require a root-owned pidfile
    # whose pid really is nfqws (a stale pid can be reused by anything).
    if command -v qm_read_pid >/dev/null 2>&1; then
        if qm_read_pid "$NFQWS_PID" nfqws >/dev/null; then
            echo "running"
        else
            echo "stopped"
        fi
        return
    fi
    if [ -f "$NFQWS_PID" ] && kill -0 "$(cat "$NFQWS_PID" 2>/dev/null)" 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# Calculate uptime from PID file timestamp
dpi_get_uptime() {
    if [ ! -f "$NFQWS_PID" ]; then
        echo "0s"
        return
    fi

    local now pid_mtime elapsed
    now=$(date +%s)
    pid_mtime=$(stat -c %Y "$NFQWS_PID" 2>/dev/null) || { echo "0s"; return; }
    elapsed=$((now - pid_mtime))

    if [ "$elapsed" -ge 86400 ]; then
        echo "$((elapsed / 86400))d $((elapsed % 86400 / 3600))h"
    elif [ "$elapsed" -ge 3600 ]; then
        echo "$((elapsed / 3600))h $((elapsed % 3600 / 60))m"
    elif [ "$elapsed" -ge 60 ]; then
        echo "$((elapsed / 60))m $((elapsed % 60))s"
    else
        echo "${elapsed}s"
    fi
}

# Read packet count from nftables rule counters in the persistent chain.
dpi_get_packet_count() {
    local count=0
    count=$(nft list chain inet fw4 mangle_postrouting_qmanager_dpi 2>/dev/null | \
        awk '/packets/ {for(i=1;i<=NF;i++) if($i=="packets") sum+=$(i+1)} END {print sum+0}')
    echo "${count:-0}"
}

# Count domains loaded from hostlist
dpi_get_domain_count() {
    if [ -f "$DPI_HOSTLIST" ]; then
        grep -v '^[[:space:]]*#' "$DPI_HOSTLIST" 2>/dev/null | grep -c -v '^[[:space:]]*$' || echo "0"
    else
        echo "0"
    fi
}