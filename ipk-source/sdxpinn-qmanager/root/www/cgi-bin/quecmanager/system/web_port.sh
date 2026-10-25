#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# web_port.sh — CGI Endpoint: QManager web port (GET + POST)
# =============================================================================
# Reads or changes the HTTP / HTTPS ports of uhttpd's main instance (shared
# with LuCI). The apply restarts uhttpd, which kills this very request, so a
# POST validates, saves UCI quecmanager.web, replies FIRST, and only then
# runs `qmanager_web_port apply` detached. That command rolls back to the old
# ports by itself if uhttpd does not come up on the new ones. Never reboots.
#
# Auth: enforced at source time by cgi_base.sh (require_auth).
#
# GET  -> {"success":true,"http_port":80,"https_port":443,
#          "listening":{"http":true,"https":true},
#          "last_result":{"status":"applied|unchanged|rolled_back|failed",
#                         "http_port":N,"https_port":N,"at":epoch}|null}
# POST {"http_port":N,"https_port":N}
#      -> {"success":true,"apply_in_progress":true|false,"http_port":N,"https_port":N}
# Errors: invalid_port | ports_equal | port_in_use | apply_failed | method_not_allowed
#
# Endpoint: GET/POST /cgi-bin/quecmanager/system/web_port.sh
# Install location: /www/cgi-bin/quecmanager/system/web_port.sh
# Doc: docs/features/web-port.md
# =============================================================================

qlog_init "cgi_web_port"
cgi_headers
cgi_handle_options

if [ ! -f /usr/lib/qmanager/web_port.sh ]; then
    cgi_error "apply_failed" "Web port library is missing"
    exit 0
fi
. /usr/lib/qmanager/web_port.sh

bool() { "$@" && echo true || echo false; }

emit_state() {
    _h=$(wp_conf_http)
    _s=$(wp_conf_https)
    _last="null"
    if [ -f "$WP_RESULT" ]; then
        read -r _st _rh _rs _at < "$WP_RESULT"
        if wp_port_valid "$_rh" && wp_port_valid "$_rs"; then
            case "$_at" in ''|*[!0-9]*) _at=0 ;; esac
            _last=$(jq -n --arg status "$_st" --argjson h "$_rh" --argjson s "$_rs" \
                --argjson at "$_at" '{status:$status, http_port:$h, https_port:$s, at:$at}')
        fi
    fi
    jq -n \
        --argjson http "$_h" \
        --argjson https "$_s" \
        --argjson lh "$(bool wp_listening "$_h")" \
        --argjson ls "$(bool wp_listening "$_s")" \
        --argjson last "$_last" \
        '{success:true, http_port:$http, https_port:$https,
          listening:{http:$lh, https:$ls}, last_result:$last}'
}

if [ "$REQUEST_METHOD" = "GET" ]; then
    emit_state
    exit 0
fi

if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post

    # Numbers only (device jq has no regex); wp_port_valid does the range check.
    HTTP_PORT=$(printf '%s' "$POST_DATA" | jq -r 'if (.http_port | type) == "number" then (.http_port | floor | tostring) else empty end' 2>/dev/null)
    HTTPS_PORT=$(printf '%s' "$POST_DATA" | jq -r 'if (.https_port | type) == "number" then (.https_port | floor | tostring) else empty end' 2>/dev/null)

    ERR=$(wp_validate "$HTTP_PORT" "$HTTPS_PORT")
    case "$ERR" in
        "") ;;
        port_in_use:*)
            cgi_error "port_in_use" "Port ${ERR#port_in_use:} is already used by another service"
            exit 0
            ;;
        ports_equal)
            cgi_error "ports_equal" "HTTP and HTTPS need different ports"
            exit 0
            ;;
        *)
            cgi_error "invalid_port" "Ports must be whole numbers from 1 to 65535"
            exit 0
            ;;
    esac

    OLD_HTTP=$(wp_uhttpd_http)
    OLD_HTTPS=$(wp_uhttpd_https)

    if ! wp_save_conf "$HTTP_PORT" "$HTTPS_PORT"; then
        cgi_error "apply_failed" "Could not save the web port setting"
        exit 0
    fi

    if [ "$HTTP_PORT" = "$OLD_HTTP" ] && [ "$HTTPS_PORT" = "$OLD_HTTPS" ]; then
        jq -n --argjson h "$HTTP_PORT" --argjson s "$HTTPS_PORT" \
            '{success:true, apply_in_progress:false, http_port:$h, https_port:$s}'
        exit 0
    fi

    qlog_info "Web port change requested: http $OLD_HTTP->$HTTP_PORT https $OLD_HTTPS->$HTTPS_PORT"
    jq -n --argjson h "$HTTP_PORT" --argjson s "$HTTPS_PORT" \
        '{success:true, apply_in_progress:true, http_port:$h, https_port:$s}'

    # Fire-and-forget: the 1 s delay flushes this response before uhttpd
    # restarts. Double fork so the apply is reparented away from uhttpd.
    ( ( sleep 1; /usr/bin/qmanager_web_port apply ) </dev/null >/dev/null 2>&1 & )
    exit 0
fi

cgi_method_not_allowed
