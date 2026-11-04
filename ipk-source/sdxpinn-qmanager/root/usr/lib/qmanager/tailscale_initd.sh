#!/bin/sh
# Canonical writer for the OFFICIAL-variant Tailscale procd init script.
# Sourced by BOTH the CGI (tailscale.sh -> write_ts_initd, fresh install) and
# install.sh's upgrade migration (migrate_tailscale_initd_boot_fix) so the
# on-disk /etc/init.d/tailscale never drifts between a fresh install and an OTA
# upgrade. OFFICIAL VARIANT ONLY — the tiny/opkg variant ships its own
# opkg-owned init script and must never be touched by this writer.
#
# This is NOT shipped as a static scripts/etc/init.d/tailscale file on purpose:
# install.sh force-copies every file under scripts/etc/init.d/ on each install,
# which would clobber the opkg-owned tiny init. Keeping the body here, written
# only on the official path, confines it correctly.
#
# Written with qm_durable_write (temp + sync + rename): a crash mid-write keeps
# the old script instead of leaving a 0-byte init.d entry. Returns 1 if the
# helper is missing or the write fails (callers already check).
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

qm_write_ts_initd() {
    command -v qm_durable_write >/dev/null 2>&1 || return 1
    qm_durable_write /etc/init.d/tailscale 0755 <<'INITD_EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

# Match the state path the QManager CGI uses (tailscale.sh connect /
# start_service). Installed by the QManager official-variant installer.
TS_STATE="/etc/tailscale/tailscaled.state"

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/tailscaled --state="$TS_STATE"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    # Intentionally does NOT run `tailscale down`. `tailscale down` persists
    # WantRunning=false in tailscaled.state, which would strand the node
    # disconnected across the next reboot (the daemon would boot idle). procd
    # stops the tracked tailscaled instance on its own when the service stops;
    # a deliberate user disconnect goes through the CGI `disconnect` action
    # (tailscale down) instead. Net effect: a plain reboot reconnects, while an
    # intentional Disconnect stays down across reboot.
    return 0
}
INITD_EOF
}
