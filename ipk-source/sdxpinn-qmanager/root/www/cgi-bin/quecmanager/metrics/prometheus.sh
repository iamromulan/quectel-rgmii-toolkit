#!/bin/sh
# prometheus.sh — Prometheus scrape endpoint (bearer token, no session cookie).
#
# Endpoint: GET /cgi-bin/quecmanager/metrics/prometheus.sh
#   Authorization: Bearer <64 lowercase hex>   (quecmanager.metrics.token)
# Response: text/plain; version=0.0.4 exposition of an ALLOWLISTED projection
# of /tmp/qmanager_status.json. Contract and data classification:
# docs/features/prometheus-metrics.md. Adding a field here is a security change.
#
# Invariants:
#   - Auth is qm_api_auth (api_auth.sh, scope "metrics"): one uniform 403 for
#     disabled, setup required, missing / malformed / wrong token and an
#     invalid stored token. A missing lib fails closed with the same bytes.
#   - The token never reaches argv, the environment of a child, or a log.
#   - Never writes /tmp/qmanager_ui_active: a scrape must not look like an open
#     browser. Only an authenticated scrape renews the poller hold file.
#   - No CORS headers: this is not a browser API. Not sourcing cgi_base.sh is
#     deliberate (its headers are JSON + CORS; its auth is the cookie path).

# Sourcing forks nothing, so no child has inherited HTTP_AUTHORIZATION yet
# when qm_api_auth moves it into a local and unsets it.
[ -f /usr/lib/qmanager/api_auth.sh ] && . /usr/lib/qmanager/api_auth.sh

if [ "$REQUEST_METHOD" != "GET" ]; then
    unset HTTP_AUTHORIZATION
    echo "Status: 405 Method Not Allowed"
    echo "Allow: GET"
    echo "Content-Type: text/plain; charset=utf-8"
    echo "Cache-Control: no-store"
    echo ""
    echo "Method Not Allowed"
    exit 0
fi

if ! command -v qm_api_auth >/dev/null 2>&1; then
    # Fail closed, byte-identical to qm_api_deny.
    unset HTTP_AUTHORIZATION
    echo "Status: 403 Forbidden"
    echo "Content-Type: text/plain; charset=utf-8"
    echo "Cache-Control: no-store"
    echo ""
    echo "Forbidden"
    exit 0
fi

qm_api_auth metrics

STATUS_FILE="/tmp/qmanager_status.json"
METRICS_RUN_DIR="/var/run/qmanager"
METRICS_SCRAPE_FILE="$METRICS_RUN_DIR/metrics_scrape"

qm_api_opt freshness
_pm_fresh="$QM_API_VAL"
case "$_pm_fresh" in
    adaptive|balanced|realtime) ;;
    *) _pm_fresh="adaptive" ;;
esac

# --- Authenticated scrape ---------------------------------------------------
echo "Content-Type: text/plain; version=0.0.4; charset=utf-8"
echo "Cache-Control: no-store"
echo ""

_pm_up=""
{ read -r _pm_up _pm_rest < /proc/uptime; } 2>/dev/null
_pm_up="${_pm_up%%.*}"
case "$_pm_up" in
    ''|*[!0-9]*|0?*|???????????*) _pm_up=0 ;;
esac

# Renew the poller hold / "last scrape" fact; a failed write never fails the
# scrape. /var/run is root 0755, so the run dir and its entries can't be
# planted: a pid-suffixed temp plus rename is atomic without mktemp.
if [ "$_pm_up" -gt 0 ]; then
    if [ ! -d "$METRICS_RUN_DIR" ] || [ -L "$METRICS_RUN_DIR" ]; then
        command -v qm_run_dir >/dev/null 2>&1 && qm_run_dir >/dev/null 2>&1
    fi
    { printf '%s %s\n' "$_pm_fresh" "$_pm_up" > "$METRICS_SCRAPE_FILE.$$" \
        && mv -f "$METRICS_SCRAPE_FILE.$$" "$METRICS_SCRAPE_FILE"; } 2>/dev/null \
        || rm -f "$METRICS_SCRAPE_FILE.$$" 2>/dev/null
fi

[ -f "$STATUS_FILE" ] || STATUS_FILE="/dev/null"

# Allowlist projection (docs/features/prometheus-metrics.md, Sections 4-5).
# Device jq has no regex: only split/join with plain strings, explode/implode.
# Every family is built here and rendered once; a missing reading yields no
# sample (never NaN), a family with no samples is not printed at all.
_PM_PROG='
def lbl: tostring | explode | map(select(. >= 32 and . != 127)) | .[0:64] | implode
    | split("\\") | join("\\\\") | split("\"") | join("\\\"");
def num: (if type == "number" then . elif type == "string" then (tonumber? // null) else null end)
    | if . == null then empty elif . != . then empty elif isinfinite then empty else . end;
# Divide, then round to 6 decimals, so 65.2 ms prints 0.0652 and not
# 0.06520000000000001. Only numbers reach it (num yields empty otherwise).
def dv($d): ((. / $d) * 1000000 + 0.5 | floor) / 1000000;
# A state label keeps only a value from its known set; anything else reads
# "other", so a future poller change can never carry free text (or an
# identifier) out through a state label. Null and "" stay null (no label).
def enum($ok): . as $v
    | if $v == null or $v == "" then null
      elif ($v | type) == "string" and ([$ok[] | select(. == $v)] | length) > 0 then $v
      else "other" end;
def b01: if . == true then 1 elif . == false then 0 else empty end;
def lc: if type == "string" then ascii_downcase else . end;
def smp(labels; v): (v | num) as $v | {l: labels, v: $v};
def fam(name; help; samples): {n: name, h: help, s: [samples]};
def sentinel($m): (($m == "rsrp" and (. == -140 or . == -32768))
    or ($m == "rsrq" and . == -32768)
    or ($m == "sinr" and (. == -20 or . == -32768)));
def render:
    . as $f
    | [ $f.s[]
        | {k: ([.l[] | select((.[1] | type) == "string" or (.[1] | type) == "number")
                     | select(.[1] != "") | "\(.[0])=\"\(.[1] | lbl)\""] | join(",")), v: .v} ]
    | unique_by(.k)
    | "# HELP \($f.n) \($f.h)\n# TYPE \($f.n) gauge\n"
      + ([.[] | $f.n + (if .k == "" then "" else "{" + .k + "}" end) + " " + (.v | tostring) + "\n"] | add);

(try input catch null) as $s
| (if ($s | type) == "object" then $s else {} end) as $d
| (($d.mono | num) // null) as $mono
| (($d.timestamp | num) // null) as $ts
| (if $up > 0 and $mono != null and $mono > 0 and $mono <= $up then $up - $mono
   elif $ts != null then ((now | floor) - $ts)
   else null end
   | if . != null and . < 0 then null else . end) as $age
| (($s | type) == "object" and $age != null and $age <= 30) as $fresh
| (($d.device // {}) | if type == "object" then . else {} end) as $dev
| (($d.network // {}) | if type == "object" then . else {} end) as $net
| (($d.lte // {}) | if type == "object" then . else {} end) as $lte
| (($d.nr // {}) | if type == "object" then . else {} end) as $nr
| (($d.connectivity // {}) | if type == "object" then . else {} end) as $con
| (($d.watchcat // {}) | if type == "object" then . else {} end) as $wc
| (($d.signal_per_antenna // {}) | if type == "object" then . else {} end) as $ant
| ([$net.carrier_components | if type == "array" then .[] else empty end | select(type == "object")
    | select((.technology | lc) == "lte" or (.technology | lc) == "nr")]) as $ccs
| def age_of($x): ($x | num) as $m | if $up > 0 and $m > 0 and $m <= $up then $up - $m else empty end;
[
  fam("qmanager_snapshot_up"; "1 if the status snapshot exists, parses and is under 30 s old.";
      smp([]; if $fresh then 1 else 0 end)),
  fam("qmanager_snapshot_age_seconds"; "Seconds since the poller last wrote the status snapshot.";
      smp([]; $age // empty)),
  fam("qmanager_build_info"; "QManager and modem build identity.";
      smp([["version", $dev.qmanager_version], ["model", $dev.model],
           ["manufacturer", $dev.manufacturer], ["firmware", $dev.firmware]]; 1))
]
+ (if $fresh then [
  fam("qmanager_serving_cell_age_seconds"; "Seconds since the serving cell was last read from the modem.";
      smp([]; age_of($dev.serving_read_mono))),
  fam("qmanager_carrier_components_age_seconds"; "Seconds since carrier aggregation was last read from the modem.";
      smp([]; age_of($dev.ca_read_mono))),
  fam("qmanager_poller_tier"; "Current adaptive poller tier (1 for the active tier).";
      ($dev.poller_tier) as $t
      | if $t == "active" or $t == "idle" or $t == "deep" then
          ("active", "idle", "deep") as $x | smp([["tier", $x]]; if $x == $t then 1 else 0 end)
        else empty end),
  fam("qmanager_scrape_freshness"; "Configured scrape freshness mode (1 for the active mode).";
      ("adaptive", "balanced", "realtime") as $x | smp([["mode", $x]]; if $x == $mode then 1 else 0 end)),
  fam("qmanager_modem_reachable"; "1 if the modem answered AT commands on the last poll.";
      smp([]; $d.modem_reachable | b01)),
  fam("qmanager_system_state"; "Current QManager system state.";
      $d.system_state | enum(["normal", "degraded", "scan_in_progress"])
      | select(. != null) | smp([["state", .]]; 1)),
  fam("qmanager_modem_cfun"; "Modem functionality level (AT+CFUN).";
      smp([]; $net.cfun)),
  fam("qmanager_network_info"; "Registered network type, carrier and service status.";
      if ($net.type // $net.carrier // $net.service_status) != null then
        smp([["network_type", ($net.type | enum(["LTE", "5G-NSA", "5G-SA"]))],
             ["carrier", $net.carrier],
             ["service_status", ($net.service_status | enum(["optimal", "connected", "limited",
                 "idle", "searching", "no_service", "sim_error", "unknown"]))]]; 1)
      else empty end),
  fam("qmanager_total_bandwidth_hertz"; "Aggregated channel bandwidth across all carriers.";
      smp([]; ($net.total_bandwidth_mhz | num) * 1000000)),
  fam("qmanager_carrier_components"; "Number of aggregated carriers by radio access technology.";
      if ($net.carrier_components | type) == "array" then
        ("lte", "nr") as $r | smp([["rat", $r]]; [$ccs[] | select((.technology | lc) == $r)] | length)
      else empty end),
  (
    [["qmanager_carrier_rsrp_dbm", "Reference signal received power per carrier.", "rsrp", 1],
     ["qmanager_carrier_rsrq_db", "Reference signal received quality per carrier.", "rsrq", 1],
     ["qmanager_carrier_rssi_dbm", "Received signal strength indicator per carrier.", "rssi", 1],
     ["qmanager_carrier_sinr_db", "Signal to interference plus noise ratio per carrier.", "sinr", 1],
     ["qmanager_carrier_bandwidth_hertz", "Channel bandwidth per carrier.", "bandwidth_mhz", 1000000]][]
    | . as $spec
    | fam($spec[0]; $spec[1];
        $ccs[] | smp([["rat", (.technology | lc)], ["role", (.type | lc | enum(["pcc", "scc"]))],
                      ["band", .band], ["pci", ([.pci | num][0])], ["earfcn", ([.earfcn | num][0])]];
                     (.[$spec[2]] | num) * $spec[3]))
  ),
  fam("qmanager_serving_rsrp_dbm"; "Serving cell reference signal received power.";
      smp([["rat", "lte"]]; $lte.rsrp), smp([["rat", "nr"]]; $nr.rsrp)),
  fam("qmanager_serving_rsrq_db"; "Serving cell reference signal received quality.";
      smp([["rat", "lte"]]; $lte.rsrq), smp([["rat", "nr"]]; $nr.rsrq)),
  fam("qmanager_serving_sinr_db"; "Serving cell signal to interference plus noise ratio.";
      smp([["rat", "lte"]]; $lte.sinr), smp([["rat", "nr"]]; $nr.sinr)),
  fam("qmanager_serving_rssi_dbm"; "Serving LTE cell received signal strength indicator.";
      smp([["rat", "lte"]]; $lte.rssi)),
  fam("qmanager_serving_cell_info"; "Serving cell state, band, PCI and channel.";
      (if ($lte.state // $lte.band // $lte.pci) != null then
         smp([["rat", "lte"], ["state", ($lte.state | enum(["connected", "searching", "inactive", "unknown"]))],
              ["band", $lte.band], ["pci", $lte.pci],
              ["earfcn", $lte.earfcn]]; 1)
       else empty end),
      (if ($nr.state // $nr.band // $nr.pci) != null then
         smp([["rat", "nr"], ["state", ($nr.state | enum(["connected", "searching", "inactive", "unknown"]))],
              ["band", $nr.band], ["pci", $nr.pci],
              ["arfcn", $nr.arfcn], ["scs_khz", $nr.scs]]; 1)
       else empty end)),
  (
    [["qmanager_antenna_rsrp_dbm", "Reference signal received power per antenna port.", "rsrp"],
     ["qmanager_antenna_rsrq_db", "Reference signal received quality per antenna port.", "rsrq"],
     ["qmanager_antenna_sinr_db", "Signal to interference plus noise ratio per antenna port.", "sinr"]][]
    | . as $spec
    | fam($spec[0]; $spec[1];
        ("lte", "nr") as $r
        | ($ant[$r + "_" + $spec[2]]) as $arr
        | if ($arr | type) == "array" then
            range(0; ([($arr | length), 4] | min)) as $i
            | ["prx", "drx", "rx2", "rx3"][$i] as $port
            | ($arr[$i] | num) as $v
            | select(($v | sentinel($spec[2])) | not)
            | smp([["rat", $r], ["port", $port]]; $v)
          else empty end)
  ),
  fam("qmanager_internet_up"; "1 if the internet reachability probe succeeds.";
      smp([]; $con.internet_available | b01)),
  fam("qmanager_connectivity_status"; "Current connection quality status.";
      $con.status | enum(["connected", "degraded", "disconnected", "recovery", "unknown"])
      | select(. != null) | smp([["status", .]]; 1)),
  fam("qmanager_ping_rtt_seconds"; "Latest ping round-trip time.";
      smp([]; ($con.latency_ms | num | dv(1000)))),
  fam("qmanager_ping_rtt_avg_seconds"; "Average ping round-trip time over the recent window.";
      smp([]; ($con.avg_latency_ms | num | dv(1000)))),
  fam("qmanager_ping_jitter_seconds"; "Ping jitter over the recent window.";
      smp([]; ($con.jitter_ms | num | dv(1000)))),
  fam("qmanager_ping_loss_ratio"; "Ping packet loss over the recent window (0 to 1).";
      smp([]; ($con.packet_loss_pct | num | dv(100)))),
  fam("qmanager_dns_lookup_seconds"; "Latest DNS lookup time.";
      smp([]; ($con.dns_lookup_ms | num | dv(1000)))),
  fam("qmanager_temperature_celsius"; "Modem temperature.";
      smp([]; $dev.temperature)),
  fam("qmanager_cpu_usage_ratio"; "CPU usage (0 to 1).";
      smp([]; ($dev.cpu_usage | num | dv(100)))),
  fam("qmanager_memory_used_bytes"; "Memory in use.";
      smp([]; ($dev.memory_used_mb | num) * 1048576)),
  fam("qmanager_memory_total_bytes"; "Total memory.";
      smp([]; ($dev.memory_total_mb | num) * 1048576)),
  fam("qmanager_system_uptime_seconds"; "Seconds since the modem booted.";
      smp([]; $dev.uptime_seconds)),
  fam("qmanager_connection_uptime_seconds"; "Seconds since the data connection came up.";
      smp([]; $dev.conn_uptime_seconds)),
  fam("qmanager_watchdog_enabled"; "1 if the connection watchdog is enabled.";
      smp([]; $wc.enabled | b01)),
  fam("qmanager_watchdog_failure_count"; "Consecutive connectivity failures seen by the watchdog.";
      smp([]; $wc.failure_count)),
  fam("qmanager_watchdog_recoveries"; "Recoveries performed by the watchdog (resets with its state).";
      smp([]; $wc.total_recoveries)),
  fam("qmanager_sim_status"; "Current SIM status.";
      (($d.sim // {}) | if type == "object" then .status else null end)
      | enum(["ready", "not_inserted", "pin_required", "puk_required", "error", "unknown"])
      | select(. != null) | smp([["status", .]]; 1))
] else [] end)
| map(select((.s | length) > 0) | render)
| add // ""
'

jq -n -j --argjson up "$_pm_up" --arg mode "$_pm_fresh" "$_PM_PROG" "$STATUS_FILE" 2>/dev/null \
    || printf '# HELP qmanager_snapshot_up 1 if the status snapshot exists, parses and is under 30 s old.\n# TYPE qmanager_snapshot_up gauge\nqmanager_snapshot_up 0\n'
