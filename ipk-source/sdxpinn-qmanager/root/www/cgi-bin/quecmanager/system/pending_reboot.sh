#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# pending_reboot.sh — CGI Endpoint: Boot-path Pending Reboot Flag Query (GET)
# =============================================================================
# Returns any pending-reboot flags written by background daemons during boot.
# Flags are cleared on read so each flag fires exactly once per boot cycle.
#
# Flags checked:
#   /tmp/qmanager_pending_reboot_verizon — written by auto_apply_profile when
#       an active Verizon MPDN profile is auto-deactivated due to SIM mismatch
#       at boot, requiring a modem reboot to restore full connectivity.
#   /tmp/qmanager_pending_reboot_package — written by the sdxpinn-qmanager
#       package postinst (install.sh --configure), which never reboots itself.
#
# Response:
#   { "verizon": true|false, "package": true|false }
#
# Endpoint: GET /cgi-bin/quecmanager/system/pending_reboot.sh
# Install location: /www/cgi-bin/quecmanager/system/pending_reboot.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_pending_reboot"
cgi_headers
cgi_handle_options

if [ "$REQUEST_METHOD" != "GET" ]; then
    cgi_method_not_allowed
fi

# --- Check and clear each flag -----------------------------------------------

# Verizon MPDN revert flag — written by auto_apply_profile on SIM mismatch
verizon_pending="false"
if [ -f /tmp/qmanager_pending_reboot_verizon ]; then
    verizon_pending="true"
    rm -f /tmp/qmanager_pending_reboot_verizon
    qlog_info "verizon pending-reboot flag consumed and cleared"
fi

# Package install/upgrade flag — written by the ipk postinst
package_pending="false"
if [ -f /tmp/qmanager_pending_reboot_package ]; then
    package_pending="true"
    rm -f /tmp/qmanager_pending_reboot_package
    qlog_info "package pending-reboot flag consumed and cleared"
fi

jq -n --argjson v "$verizon_pending" --argjson p "$package_pending" '{verizon: $v, package: $p}'
