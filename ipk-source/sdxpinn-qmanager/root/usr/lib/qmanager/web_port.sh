#!/bin/sh
# =============================================================================
# web_port.sh — QManager web port library (uhttpd main instance)
# =============================================================================
# QManager and LuCI share uhttpd's `main` instance, so moving the port moves
# both. The user's choice lives in UCI `quecmanager.web` (http_port,
# https_port); wp_apply pushes it into uhttpd.main.listen_http / listen_https
# (each bind address keeps its host part, only the port changes), restarts
# uhttpd, and rolls back to the previous ports if uhttpd does not come up on
# the new ones. Never reboots.
#
# Callers: /usr/bin/qmanager_web_port (SSH CLI, also run detached by the CGI),
#          /www/cgi-bin/quecmanager/system/web_port.sh, install.sh, uninstall.sh
# Doc: docs/features/web-port.md
# =============================================================================

[ -n "$_WEB_PORT_LOADED" ] && return 0
_WEB_PORT_LOADED=1

WP_DEFAULT_HTTP=80
WP_DEFAULT_HTTPS=443
WP_LOCK="/var/lock/qmanager_web_port.lock"
WP_RESULT="/var/run/qmanager/web_port.result"
WP_VERIFY_S=10

_wp_log() {
    command -v qlog_info >/dev/null 2>&1 && qlog_info "$*"
    return 0
}

# wp_port_valid <n> -> 0 when n is an integer in 1..65535 (no leading zeros).
wp_port_valid() {
    case "$1" in
        ''|*[!0-9]*|0*) return 1 ;;
    esac
    [ "${#1}" -le 5 ] || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# _wp_list_port "<entries>" -> port of the first entry ("0.0.0.0:80" -> 80).
_wp_list_port() {
    _wlp_first=""
    for _wlp_e in $1; do _wlp_first="$_wlp_e"; break; done
    [ -n "$_wlp_first" ] || return 0
    printf '%s\n' "${_wlp_first##*:}"
}

# Ports uhttpd is configured for right now (empty when unset).
wp_uhttpd_http()  { _wp_list_port "$(uci -q get uhttpd.main.listen_http)"; }
wp_uhttpd_https() { _wp_list_port "$(uci -q get uhttpd.main.listen_https)"; }

# Ports the user chose (quecmanager.web), falling back to uhttpd, then default.
wp_conf_http() {
    _wch=$(uci -q get quecmanager.web.http_port)
    wp_port_valid "$_wch" || _wch=$(wp_uhttpd_http)
    wp_port_valid "$_wch" || _wch=$WP_DEFAULT_HTTP
    printf '%s\n' "$_wch"
}
wp_conf_https() {
    _wcs=$(uci -q get quecmanager.web.https_port)
    wp_port_valid "$_wcs" || _wcs=$(wp_uhttpd_https)
    wp_port_valid "$_wcs" || _wcs=$WP_DEFAULT_HTTPS
    printf '%s\n' "$_wcs"
}

# _wp_listeners <port> -> "PID/name" of every TCP listener on that port.
_wp_listeners() {
    netstat -ltnp 2>/dev/null | awk -v p="$1" '
        $1 ~ /^tcp/ { n = split($4, a, ":"); if (a[n] == p) print $NF }'
}

# wp_listening <port> -> 0 when uhttpd is listening on it.
wp_listening() {
    _wp_listeners "$1" | grep -q '/uhttpd'
}

# wp_port_taken <port> -> 0 when something other than uhttpd listens on it.
wp_port_taken() {
    _wp_listeners "$1" | grep -qv '/uhttpd'
}

# wp_validate <http> <https> -> prints an error code and returns 1 on failure.
# Codes: invalid_port | ports_equal | port_in_use
wp_validate() {
    if ! wp_port_valid "$1" || ! wp_port_valid "$2"; then
        echo "invalid_port"; return 1
    fi
    if [ "$1" = "$2" ]; then
        echo "ports_equal"; return 1
    fi
    if wp_port_taken "$1"; then
        echo "port_in_use:$1"; return 1
    fi
    if wp_port_taken "$2"; then
        echo "port_in_use:$2"; return 1
    fi
    return 0
}

# wp_save_conf <http> <https> -> write quecmanager.web and commit.
wp_save_conf() {
    uci -q get quecmanager.web >/dev/null 2>&1 || uci set quecmanager.web=web
    uci set quecmanager.web.http_port="$1"
    uci set quecmanager.web.https_port="$2"
    uci commit quecmanager
}

# _wp_set_list <option> <port> <default entries>
# Rewrites uhttpd.main.<option> keeping each entry's bind address.
_wp_set_list() {
    _wsl_old=$(uci -q get "uhttpd.main.$1")
    [ -n "$_wsl_old" ] || _wsl_old="$3"
    uci -q delete "uhttpd.main.$1" || true
    for _wsl_e in $_wsl_old; do
        case "$_wsl_e" in
            *:*) uci add_list "uhttpd.main.$1=${_wsl_e%:*}:$2" ;;
            *)   uci add_list "uhttpd.main.$1=$2" ;;
        esac
    done
}

# _wp_restore_list <option> "<entries>"
_wp_restore_list() {
    uci -q delete "uhttpd.main.$1" || true
    for _wrl_e in $2; do
        uci add_list "uhttpd.main.$1=$_wrl_e"
    done
}

# wp_write_uhttpd <http> <https> -> rewrite uhttpd.main listen lists + commit.
# No restart (install.sh uses this ahead of its reboot).
wp_write_uhttpd() {
    _wp_set_list listen_http "$1" "0.0.0.0:$WP_DEFAULT_HTTP [::]:$WP_DEFAULT_HTTP"
    _wp_set_list listen_https "$2" "0.0.0.0:$WP_DEFAULT_HTTPS [::]:$WP_DEFAULT_HTTPS"
    uci commit uhttpd
}

_wp_wait_listening() {
    _wwl_i=0
    while [ "$_wwl_i" -lt "$WP_VERIFY_S" ]; do
        wp_listening "$1" && wp_listening "$2" && return 0
        sleep 1
        _wwl_i=$((_wwl_i + 1))
    done
    return 1
}

_wp_result() {
    mkdir -p "${WP_RESULT%/*}" 2>/dev/null
    printf '%s %s %s %s\n' "$1" "$2" "$3" "$(date +%s)" > "$WP_RESULT" 2>/dev/null
}

# wp_apply -> push quecmanager.web into uhttpd and restart it, with rollback.
# Prints one status line and returns:
#   0 "applied <http> <https>" | "unchanged <http> <https>"
#   1 "rolled_back <http> <https>" (back on the old ports) | "failed <reason>"
wp_apply() {
    _wa_http=$(wp_conf_http)
    _wa_https=$(wp_conf_https)

    # BusyBox flock has no -w: poll -n for up to 30 s.
    exec 8>"$WP_LOCK"
    _wa_i=0
    until flock -n 8; do
        _wa_i=$((_wa_i + 1))
        if [ "$_wa_i" -ge 30 ]; then
            exec 8>&-
            echo "failed busy"; return 1
        fi
        sleep 1
    done

    _wa_old_http_list=$(uci -q get uhttpd.main.listen_http)
    _wa_old_https_list=$(uci -q get uhttpd.main.listen_https)
    _wa_old_http=$(wp_uhttpd_http)
    _wa_old_https=$(wp_uhttpd_https)

    if [ "$_wa_http" = "$_wa_old_http" ] && [ "$_wa_https" = "$_wa_old_https" ] \
        && wp_listening "$_wa_http" && wp_listening "$_wa_https"; then
        exec 8>&-
        _wp_result unchanged "$_wa_http" "$_wa_https"
        echo "unchanged $_wa_http $_wa_https"; return 0
    fi

    _wa_err=$(wp_validate "$_wa_http" "$_wa_https") || true
    if [ -n "$_wa_err" ]; then
        exec 8>&-
        _wp_result failed "$_wa_old_http" "$_wa_old_https"
        echo "failed $_wa_err"; return 1
    fi

    wp_write_uhttpd "$_wa_http" "$_wa_https"
    /etc/init.d/uhttpd restart >/dev/null 2>&1 8>&- || true

    if _wp_wait_listening "$_wa_http" "$_wa_https"; then
        exec 8>&-
        _wp_log "Web port moved to http=$_wa_http https=$_wa_https"
        _wp_result applied "$_wa_http" "$_wa_https"
        echo "applied $_wa_http $_wa_https"; return 0
    fi

    # uhttpd did not come up on the new ports: put the old ones back.
    _wp_restore_list listen_http "$_wa_old_http_list"
    _wp_restore_list listen_https "$_wa_old_https_list"
    uci commit uhttpd
    if wp_port_valid "$_wa_old_http" && wp_port_valid "$_wa_old_https"; then
        wp_save_conf "$_wa_old_http" "$_wa_old_https"
    fi
    /etc/init.d/uhttpd restart >/dev/null 2>&1 8>&- || true
    _wp_wait_listening "$_wa_old_http" "$_wa_old_https" || true
    exec 8>&-
    _wp_log "Web port move to http=$_wa_http https=$_wa_https failed; rolled back"
    _wp_result rolled_back "$_wa_old_http" "$_wa_old_https"
    echo "rolled_back $_wa_old_http $_wa_old_https"; return 1
}
