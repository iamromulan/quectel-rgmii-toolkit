#!/bin/sh
# =============================================================================
# download.sh — GET ?job_id=<id>: stream the health check support bundle.
# =============================================================================
# cgi_base.sh enforces auth while it is sourced (401 JSON on failure). On
# success it emits nothing, so the binary headers below are the only ones.
# =============================================================================

. /usr/lib/qmanager/cgi_base.sh
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

_json_status() {
    printf 'Status: %s\r\n' "$1"
    printf 'Content-Type: application/json\r\n'
    printf 'Cache-Control: no-cache, no-store, must-revalidate\r\n\r\n'
    printf '{"success":false,"error":"%s"}\n' "$2"
    exit 0
}

if [ "$REQUEST_METHOD" != "GET" ]; then
    _json_status "405 Method Not Allowed" "method_not_allowed"
fi

job_id=""
case "$QUERY_STRING" in
    job_id=*|*'&job_id='*)
        job_id=$(printf '%s' "$QUERY_STRING" | sed -n 's/^\(.*&\)\{0,1\}job_id=\([^&]*\).*/\2/p') ;;
esac
case "$job_id" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) _json_status "400 Bad Request" "invalid_job_id" ;;
esac

tarball="/tmp/qmanager_health_check_${job_id}.tar.gz"
# B4.1: serve only a root-owned bundle (fails closed if the helper lib is missing)
if ! qm_trusted_file "$tarball"; then
    _json_status "404 Not Found" "bundle_not_found"
fi

size=$(wc -c < "$tarball" 2>/dev/null | tr -d ' ')
case "$size" in ''|*[!0-9]*) size=0 ;; esac

printf 'Content-Type: application/gzip\r\n'
printf 'Content-Length: %s\r\n' "$size"
printf 'Content-Disposition: attachment; filename="qmanager-health-check-%s.tar.gz"\r\n' "$job_id"
printf 'Cache-Control: no-cache, no-store, must-revalidate\r\n'
printf '\r\n'
cat "$tarball"
