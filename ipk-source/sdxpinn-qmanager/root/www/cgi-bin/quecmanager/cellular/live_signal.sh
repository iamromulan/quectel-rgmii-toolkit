#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# live_signal.sh — CGI Endpoint: real-time signal lease (POST)
# =============================================================================
# POST ?tier=aim|watch renews the live-signal lease and returns the capability
# URL of the static file the broker publishes while a lease is fresh. No body
# is read and no client number reaches the broker: the tier is the only input
# and it selects a compiled period. See docs/plans/2026-10-22-qmi-phase2-live-tiers.md
# (L1-L7).
#
# Runtime files (root-only /var/run/qmanager, 0700):
#   qmi_live_<tier>   one line: /proc/uptime integer seconds (the stamp)
#   qmi_live.token    64 lowercase hex, the capability URL token
#   qmi_live.lock     flock target shared with the broker's expiry path
#
# Forks per renewal: flock -n, mv (+ head/openssl/awk only when minting).
#
# Endpoint: POST /cgi-bin/quecmanager/cellular/live_signal.sh?tier=aim|watch
# Install location: /www/cgi-bin/quecmanager/cellular/live_signal.sh
# =============================================================================

qlog_init "cgi_live_signal"
cgi_headers
cgi_handle_options

LIVE_RUN="${QM_LIVE_RUN:-/var/run/qmanager}"
LIVE_PROTO="${QM_LIVE_PROTO:-/var/run/qmanager_atd.proto}"
LIVE_QMI_BIN="${QM_LIVE_QMI_BIN:-/usr/bin/qmi}"

[ "$REQUEST_METHOD" = "POST" ] || cgi_method_not_allowed

case "$QUERY_STRING" in
    tier=aim)   period_ms=1000 ;; # 1 Hz final, 5 Hz dropped; matches live.rs AIM_PERIOD
    tier=watch) period_ms=1000 ;;
    *) cgi_error "bad_tier" "tier must be aim or watch"; exit 0 ;;
esac
tier="${QUERY_STRING#tier=}"

# Capability: the running broker must advertise both the QMI lane and the live
# sampler. A rolled-back broker never writes live=1, so the UI falls back to 2 s.
have_qmi=0
have_live=0
if [ -x "$LIVE_QMI_BIN" ] && [ -f "$LIVE_PROTO" ]; then
    while read -r line; do
        case "$line" in
            qmi=1)  have_qmi=1 ;;
            live=1) have_live=1 ;;
        esac
    done < "$LIVE_PROTO"
fi
if [ "$have_qmi" != "1" ] || [ "$have_live" != "1" ]; then
    printf '%s\n' '{"success":true,"available":false}'
    exit 0
fi

lease_failed() {
    qlog_warn "lease failed: $1"
    cgi_error "lease_failed" "$1"
    exit 0
}

[ -d "$LIVE_RUN" ] && [ ! -L "$LIVE_RUN" ] || lease_failed "run dir unavailable"

# The lock fd closes with the process, so every exit path releases it.
# A failing exec redirect aborts an ash script, so probe the path first.
true >> "$LIVE_RUN/qmi_live.lock" 2>/dev/null || lease_failed "lock unavailable"
exec 9>> "$LIVE_RUN/qmi_live.lock"
# BusyBox flock has no -w: try non-blocking, retry for ~1 s (forks only on contention).
tries=0
until flock -n 9; do
    tries=$((tries + 1))
    [ "$tries" -ge 10 ] && lease_failed "lock busy"
    sleep 0.1
done

up=""
read -r up _rest < /proc/uptime
up="${up%%.*}"
case "$up" in
    ''|*[!0-9]*) lease_failed "uptime unreadable" ;;
esac

stamp="$LIVE_RUN/qmi_live_$tier"
tmp="$stamp.$$"
printf '%s\n' "$up" > "$tmp" 2>/dev/null || { rm -f "$tmp"; lease_failed "stamp write failed"; }
mv -f "$tmp" "$stamp" 2>/dev/null || { rm -f "$tmp"; lease_failed "stamp rename failed"; }

token=""
[ -f "$LIVE_RUN/qmi_live.token" ] && [ ! -L "$LIVE_RUN/qmi_live.token" ] && \
    read -r token < "$LIVE_RUN/qmi_live.token" 2>/dev/null
valid=1
case "$token" in
    *[!0-9a-f]*) valid=0 ;;
esac
[ "${#token}" -eq 64 ] || valid=0

if [ "$valid" != "1" ]; then
    token=$(qm_generate_token)
    case "$token" in
        *[!0-9a-f]*) lease_failed "token generation failed" ;;
    esac
    [ "${#token}" -eq 64 ] || lease_failed "token generation failed"
    printf '%s\n' "$token" > "$LIVE_RUN/qmi_live.token.$$" 2>/dev/null \
        && chmod 600 "$LIVE_RUN/qmi_live.token.$$" 2>/dev/null \
        && mv -f "$LIVE_RUN/qmi_live.token.$$" "$LIVE_RUN/qmi_live.token" 2>/dev/null \
        || { rm -f "$LIVE_RUN/qmi_live.token.$$"; lease_failed "token write failed"; }
    qlog_info "minted live token (tier=$tier)"
fi

printf '{"success":true,"available":true,"url":"/qmlive/%s.json","period_ms":%s,"renew_s":5,"ttl_s":10}\n' \
    "$token" "$period_ms"
