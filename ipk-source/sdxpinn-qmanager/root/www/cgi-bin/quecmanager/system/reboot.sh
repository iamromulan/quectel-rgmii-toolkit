#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# reboot.sh — CGI Endpoint: System Reboot (POST only)
# =============================================================================
# POST: Triggers a device reboot after flushing the HTTP response.
# =============================================================================

case "$REQUEST_METHOD" in
    POST)
        qlog_info "Device reboot requested via system menu"
        cgi_reboot_response "user"
        ;;
    *)
        cgi_error "method_not_allowed" "Only POST is supported"
        ;;
esac
