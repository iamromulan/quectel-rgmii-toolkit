#!/bin/sh
# =============================================================================
# at_engine.sh — qcmd/qsms links + host AT port (port-bridge) control
# =============================================================================
# Sourced by /etc/init.d/qmanager_atd, system/host_at_ports.sh and install.sh.
# See docs/features/at-broker.md.
#
# qcmd: /usr/bin/qcmd is a SYMLINK to qmanager_atd, the Rust AT broker. The
#   binary is multicall: run as qcmd it acts as the client, talking to the
#   broker socket and falling back to an in-process exchange when the daemon
#   is down, so AT keeps working without the daemon. The output contract is
#   the one every caller has always parsed (echo + body + OK).
#
# qsms: /usr/bin/qsms is a second SYMLINK to qmanager_atd. Run as qsms it is
#   the SMS client (list / status / send / delete, one JSON line on stdout),
#   same socket-then-in-process transport as qcmd. The broker takes the modem
#   lock itself, so callers must NOT wrap qsms in flock on qmanager.lock.
#
# Host AT ports (UCI quecmanager.ports.host_at = 1 | 0, default 1):
#   The vendor port-bridged service relays the USB/PCIe host AT ports into the
#   baseband (at_mdm0<->at_usb0, smd7<->at_usb2 or mhi_pipe_32). QManager never
#   uses them; turning them off stops a USB/PCIe-attached host from issuing AT
#   commands and closes the world-writable /dev/smd7 path. It does not change
#   QManager's own AT speed (that path is /dev/smd11).
#
# Install location: /usr/lib/qmanager/at_engine.sh
# =============================================================================

[ -n "$_AT_ENGINE_LOADED" ] && return 0
_AT_ENGINE_LOADED=1

ATE_BROKER_BIN="/usr/bin/qmanager_atd"
ATE_LINK="/usr/bin/qcmd"
ATE_SMS_LINK="/usr/bin/qsms"
ATE_QMI_LINK="/usr/bin/qmi"
ATE_LIVE_DIR="/var/run/qmanager/live"
ATE_LIVE_LINK="/www/qmlive"
ATE_SOCK="/var/run/qmanager_atd.sock"
PB_INIT="/etc/init.d/port-bridged"

# --- qcmd link ---------------------------------------------------------------

at_broker_available() {
    [ -x "$ATE_BROKER_BIN" ]
}

at_broker_running() {
    [ -S "$ATE_SOCK" ] && pidof qmanager_atd >/dev/null 2>&1
}

# Atomically repoint a client link ($1 = link path) at $2. ln -sf would unlink
# then create, leaving a moment with no link at all; a temp link + rename(2)
# never does. The rename also replaces a regular file an old install left at
# that path. Temp names are /usr/bin/.qcmd.<pid> / .qsms.<pid> / .qmi.<pid>.
_ate_link_to() {
    _ate_tmp="${1%/*}/.${1##*/}.$$"
    rm -f "$_ate_tmp"
    ln -s "$2" "$_ate_tmp" || return 1
    if ! mv -f "$_ate_tmp" "$1"; then
        rm -f "$_ate_tmp"
        return 1
    fi
    return 0
}

# Point /usr/bin/qcmd at qmanager_atd. Idempotent.
at_qcmd_link() {
    [ -L "$ATE_LINK" ] && [ "$(readlink "$ATE_LINK" 2>/dev/null)" = "qmanager_atd" ] && return 0
    _ate_link_to "$ATE_LINK" "qmanager_atd"
}

# Point /usr/bin/qsms at qmanager_atd. Idempotent.
at_qsms_link() {
    [ -L "$ATE_SMS_LINK" ] && [ "$(readlink "$ATE_SMS_LINK" 2>/dev/null)" = "qmanager_atd" ] && return 0
    _ate_link_to "$ATE_SMS_LINK" "qmanager_atd"
}

# Point /usr/bin/qmi at qmanager_atd. Idempotent. Unconditional like qsms: callers
# gate on the daemon-written capability file (qmi=1), so a link left behind by a
# rollback to a binary without the QMI lane is inert, not an error.
at_qmi_link() {
    [ -L "$ATE_QMI_LINK" ] && [ "$(readlink "$ATE_QMI_LINK" 2>/dev/null)" = "qmanager_atd" ] && return 0
    _ate_link_to "$ATE_QMI_LINK" "qmanager_atd"
}

# Point /www/qmlive at the broker's public live-signal dir (served by uhttpd,
# which follows the symlink). The target sits under the root-only run dir, never
# /tmp: a world-writable parent would let a local user plant content served
# same-origin. The broker owns and creates the target; this only manages the link. Idempotent.
# The frontend install wipes /www/*, so install.sh re-runs this after install_frontend and the init script on every
# start. Never writes through a real directory: that is refused (rc 1), and a
# wrong symlink is removed first because mv onto a symlink-to-dir would move the
# new link INTO the target.
at_live_link() {
    [ -L "$ATE_LIVE_LINK" ] && [ "$(readlink "$ATE_LIVE_LINK" 2>/dev/null)" = "$ATE_LIVE_DIR" ] && return 0
    [ -d "$ATE_LIVE_LINK" ] && [ ! -L "$ATE_LIVE_LINK" ] && return 1
    [ -d "${ATE_LIVE_LINK%/*}" ] || return 1
    [ -L "$ATE_LIVE_LINK" ] && rm -f "$ATE_LIVE_LINK"
    _ate_link_to "$ATE_LIVE_LINK" "$ATE_LIVE_DIR"
}

# --- Host AT ports (port-bridge) ---------------------------------------------

host_at_available() {
    [ -x "$PB_INIT" ]
}

# Configured state: 1 (on, default) or 0 (off).
host_at_get() {
    [ "$(uci -q get quecmanager.ports.host_at)" = "0" ] && echo 0 || echo 1
}

host_at_running() {
    pidof port-bridge >/dev/null 2>&1
}

# In PCIe mode the host's AT port is the PCIe link itself.
host_at_pcie() {
    [ -e /dev/mhi_ctrl ]
}

# Reconcile live state to UCI. Idempotent; safe at boot and on every apply.
# disable/enable persist across reboots (rc.d links); a firmware update can
# reset them, so qmanager_atd re-runs this at boot.
host_at_apply() {
    host_at_available || return 0
    if [ "$(host_at_get)" = "0" ]; then
        "$PB_INIT" enabled >/dev/null 2>&1 && "$PB_INIT" disable >/dev/null 2>&1
        # procd stop kills both instances and suppresses respawn.
        host_at_running && "$PB_INIT" stop >/dev/null 2>&1
        # port-bridged chmods /dev/smd7 777 on start; close that direct path
        # into the AT engine while the bridge is off. Its start restores it.
        [ -c /dev/smd7 ] && chmod 600 /dev/smd7 2>/dev/null
    else
        "$PB_INIT" enabled >/dev/null 2>&1 || "$PB_INIT" enable >/dev/null 2>&1
        host_at_running || "$PB_INIT" start >/dev/null 2>&1
    fi
    return 0
}
