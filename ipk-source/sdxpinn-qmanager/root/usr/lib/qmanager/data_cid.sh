#!/bin/sh
# =============================================================================
# data_cid.sh — QManager data-bearing PDP context (CID) detection
# =============================================================================
# Answers "which CID carries the internet data?" WITHOUT AT+QMAP, which several
# firmwares (RM551E-GL fw ...R02A01M8G) do not implement at all.
#
# Evidence, strongest first (first match wins):
#   route         the kernel default-route source address equals a candidate
#                 CID's IPv4 (authoritative, even for a service-looking APN)
#   local         exactly one candidate's IPv4 is on a local interface
#   ipv6_prefix   exactly one candidate's IPv6 /64 is a local global /64
#   pdp           lowest-numbered candidate that is not a service APN
#   none          bearer down, or only IMS/SOS-type contexts are up
#
# A candidate is a CID whose CGACT state is 1 (or unknown) and that has an
# IPv4 or global IPv6 address in AT+CGPADDR.
#
# The parser is PURE: it takes the AT blob plus the kernel facts as arguments,
# so it is fixture-testable off-device. qm_kernel_wan_facts reads the facts.
#
# Source with:  [ -f /usr/lib/qmanager/data_cid.sh ] && . /usr/lib/qmanager/data_cid.sh
# POSIX/BusyBox only. Dependencies: awk, ip (only qm_kernel_wan_facts).
#
# API
#   qm_apn_class <apn>        -> prints "ims", "emergency" or "" (UI tag)
#   qm_kernel_wan_facts       -> sets QM_K_ROUTE_SRC, QM_K_LOCAL4, QM_K_LOCAL6
#   qm_parse_data_cid <blob> <route_src_list> <local4_list> <local6_list>
#   qm_detect_data_cid <blob> -> qm_kernel_wan_facts + qm_parse_data_cid
#
# Results (globals): QM_DATA_CID, QM_DATA_CID_SOURCE, QM_DATA_IPV4,
#   QM_DATA_IPV6, QM_CID_ROWS — one line per CID, pipe-delimited:
#   cid|activated(1/0/empty)|ipv4|ipv6|candidate(1/0)|apn
# =============================================================================

[ -n "$_QM_DATA_CID_LOADED" ] && return 0
_QM_DATA_CID_LOADED=1

# qm_apn_class <apn> — carrier-managed context tag (case-insensitive substring,
# kept identical to the historic apn.sh apn_type_of classification).
qm_apn_class() {
    _qc_lc=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    case "$_qc_lc" in
        *ims*)                          echo "ims" ;;
        *sos*|*emergency*|*xcap*|*rcs*) echo "emergency" ;;
        *)                              echo "" ;;
    esac
}

# qm_kernel_wan_facts — read default-route sources and local addresses.
# All three are space-separated lists ("" when unavailable).
qm_kernel_wan_facts() {
    QM_K_ROUTE_SRC=$(ip -4 route show default 2>/dev/null | awk '
        { for (i = 1; i < NF; i++) if ($i == "src") { printf "%s ", $(i + 1) } }')
    QM_K_LOCAL4=$(ip -o -4 addr show 2>/dev/null | awk '
        { for (i = 1; i < NF; i++) if ($i == "inet") { a = $(i + 1); sub(/\/.*/, "", a); printf "%s ", a } }')
    QM_K_LOCAL6=$(ip -o -6 addr show scope global 2>/dev/null | awk '
        { for (i = 1; i < NF; i++) if ($i == "inet6") { a = $(i + 1); sub(/\/.*/, "", a); printf "%s ", a } }')
}

# qm_parse_data_cid <blob> <route_src_list> <local4_list> <local6_list>
# The blob is any mix of +CGDCONT / +CGACT / +CGPADDR lines (other lines, e.g.
# a stray +QMAP, are ignored). Always returns 0.
qm_parse_data_cid() {
    _qd_out=$(printf '%s\n' "$1" | awk -v route="$2" -v loc4="$3" -v loc6="$4" '
        # 16 dotted octets or colon-hex -> 8 normalised hex groups, or "".
        function full6(s,   n, o, i, k, g, h, t, hh, tt, nh, nt, miss, p, out, v) {
            s = tolower(s)
            if (s !~ /:/) {
                n = split(s, o, ".")
                if (n != 16) return ""
                out = ""
                for (i = 1; i <= 16; i += 2) {
                    if (o[i] !~ /^[0-9]+$/ || o[i + 1] !~ /^[0-9]+$/) return ""
                    v = sprintf("%x", o[i] * 256 + o[i + 1])
                    out = out (i > 1 ? ":" : "") v
                }
                return out
            }
            if (s !~ /^[0-9a-f:]+$/) return ""
            p = index(s, "::")
            k = 0
            if (p > 0) {
                h = substr(s, 1, p - 1); t = substr(s, p + 2)
                nh = (h == "") ? 0 : split(h, hh, ":")
                nt = (t == "") ? 0 : split(t, tt, ":")
                miss = 8 - nh - nt
                if (miss < 1) return ""
                for (i = 1; i <= nh; i++) g[++k] = hh[i]
                for (i = 1; i <= miss; i++) g[++k] = "0"
                for (i = 1; i <= nt; i++) g[++k] = tt[i]
            } else {
                if (split(s, g, ":") != 8) return ""
                k = 8
            }
            out = ""
            for (i = 1; i <= 8; i++) {
                v = g[i]; sub(/^0+/, "", v); if (v == "") v = "0"
                if (length(v) > 4) return ""
                out = out (i > 1 ? ":" : "") v
            }
            return out
        }
        function pfx6(f,   a) {
            split(f, a, ":")
            return a[1] ":" a[2] ":" a[3] ":" a[4]
        }
        function isv4(s,   o) {
            if (split(s, o, ".") != 4) return 0
            if (s !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0
            return 1
        }
        # Service/IMS-type APN by whole label, not substring.
        function is_service(apn,   n, l, i) {
            apn = tolower(apn)
            n = split(apn, l, ".")
            for (i = 1; i <= n; i++)
                if (l[i] ~ /^(ims|sos|xcap|ut|rcs|mms|admin|fota|supl|emergency|vzwims|vzwadmin|vzwapp)$/) return 1
            return 0
        }
        function trim(v) { gsub(/^[ \t"]+|[ \t"]+$/, "", v); return v }
        BEGIN {
            nr = split(route, ra, " "); for (i = 1; i <= nr; i++) rset[ra[i]] = 1
            n4 = split(loc4, l4, " "); for (i = 1; i <= n4; i++) l4set[l4[i]] = 1
            n6 = split(loc6, l6, " ")
            for (i = 1; i <= n6; i++) { ff = full6(l6[i]); if (ff != "") l6set[pfx6(ff)] = 1 }
            maxcid = 0
        }
        {
            gsub(/\r/, "")
            if ($0 ~ /^\+CGDCONT:/) {
                line = $0; sub(/^\+CGDCONT:[ \t]*/, "", line)
                if (line !~ /^[0-9]+,/) next
                cid = line + 0
                split(line, q, "\"")
                apn[cid] = q[4]; seen[cid] = 1
                if (cid > maxcid) maxcid = cid
            } else if ($0 ~ /^\+CGACT:/) {
                line = $0; sub(/^\+CGACT:[ \t]*/, "", line)
                if (line !~ /^[0-9]+[ \t]*,/) next
                split(line, f, ",")
                cid = trim(f[1]) + 0
                act[cid] = (trim(f[2]) == "1") ? 1 : 0
                seen[cid] = 1
                if (cid > maxcid) maxcid = cid
            } else if ($0 ~ /^\+CGPADDR:/) {
                line = $0; sub(/^\+CGPADDR:[ \t]*/, "", line)
                if (line !~ /^[0-9]+[ \t]*(,|$)/) next
                nf = split(line, f, ",")
                cid = trim(f[1]) + 0
                seen[cid] = 1
                if (cid > maxcid) maxcid = cid
                for (i = 2; i <= nf; i++) {
                    a = trim(f[i])
                    if (a == "") continue
                    if (a !~ /:/ && isv4(a)) {
                        if (a !~ /^0+\.0+\.0+\.0+$/ && v4[cid] == "") v4[cid] = a
                    } else {
                        full = full6(a)
                        if (full == "") continue
                        p = pfx6(full)
                        if (p == "0:0:0:0" || p ~ /^fe[89ab][0-9a-f]?:/) continue
                        if (v6[cid] == "") { v6[cid] = full; p6[cid] = p }
                    }
                }
            }
        }
        END {
            for (c = 0; c <= maxcid; c++) {
                if (!(c in seen)) continue
                cand[c] = ((c in act) ? (act[c] == 1) : 1) && (v4[c] != "" || v6[c] != "")
                a = apn[c]; gsub(/\|/, "_", a)
                printf "%d|%s|%s|%s|%d|%s\n", c, (c in act) ? act[c] : "", v4[c], v6[c], cand[c] ? 1 : 0, a
            }
            sel = -1; src = "none"
            # 1. default-route source
            for (c = 0; c <= maxcid && sel < 0; c++)
                if (cand[c] && v4[c] != "" && (v4[c] in rset)) { sel = c; src = "route" }
            # 2. exactly one candidate IPv4 on a local interface
            if (sel < 0) {
                cnt = 0
                for (c = 0; c <= maxcid; c++)
                    if (cand[c] && v4[c] != "" && (v4[c] in l4set)) { cnt++; pick = c }
                if (cnt == 1) { sel = pick; src = "local" }
            }
            # 3. exactly one candidate IPv6 /64 is a local global /64
            if (sel < 0) {
                cnt = 0
                for (c = 0; c <= maxcid; c++)
                    if (cand[c] && v6[c] != "" && (p6[c] in l6set)) { cnt++; pick = c }
                if (cnt == 1) { sel = pick; src = "ipv6_prefix" }
            }
            # 4. lowest candidate that is not a service APN
            if (sel < 0) {
                for (c = 0; c <= maxcid && sel < 0; c++)
                    if (cand[c] && !is_service(apn[c])) { sel = c; src = "pdp" }
            }
            if (sel >= 0) printf "#D|%d|%s|%s|%s\n", sel, src, v4[sel], v6[sel]
            else printf "#D||none||\n"
        }')

    QM_DATA_CID=""
    QM_DATA_CID_SOURCE="none"
    QM_DATA_IPV4=""
    QM_DATA_IPV6=""
    QM_CID_ROWS=$(printf '%s\n' "$_qd_out" | grep -v '^#D|')
    _qd_dec=$(printf '%s\n' "$_qd_out" | grep '^#D|' | head -1)
    if [ -n "$_qd_dec" ]; then
        _qd_old_ifs=$IFS
        IFS='|'
        # shellcheck disable=SC2086
        set -- $_qd_dec
        IFS=$_qd_old_ifs
        QM_DATA_CID="$2"
        QM_DATA_CID_SOURCE="${3:-none}"
        QM_DATA_IPV4="$4"
        QM_DATA_IPV6="$5"
    fi
    return 0
}

# qm_detect_data_cid <blob> — kernel facts + parse in one call.
qm_detect_data_cid() {
    qm_kernel_wan_facts
    qm_parse_data_cid "$1" "$QM_K_ROUTE_SRC" "$QM_K_LOCAL4" "$QM_K_LOCAL6"
}
