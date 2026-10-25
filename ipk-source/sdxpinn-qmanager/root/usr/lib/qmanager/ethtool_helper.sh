#!/bin/sh
# Ethtool helper library — shared utilities for ethernet link management.

[ -n "$_ETHTOOL_HELPER_LOADED" ] && return 0
_ETHTOOL_HELPER_LOADED=1

# ---------------------------------------------------------------------------
# get_supported_advertise_hex
# Build the ethtool --advertise hex mask for all link modes supported by
# $ETH_INTERFACE. Handles modes beyond the 32-bit legacy range (e.g.
# 2500baseT/Full = bit 47) by splitting into hi/lo 32-bit halves.
#
# Requires: $ETH_INTERFACE to be set by the caller.
# Output:   Hex string on stdout (e.g. "0x2f", "0x100000002f")
# ---------------------------------------------------------------------------
get_supported_advertise_hex() {
    ethtool "$ETH_INTERFACE" 2>/dev/null | \
        sed -n '/Supported link modes:/,/Supported pause frame use:/p' | \
        sed '1s/.*Supported link modes:[[:space:]]*//' | \
        sed '/Supported pause frame use:/d' | \
        tr -s ' \t\n' '\n' | \
        awk '
        BEGIN {
            b["10baseT/Half"]=0;       b["10baseT/Full"]=1
            b["100baseT/Half"]=2;      b["100baseT/Full"]=3
            b["1000baseT/Half"]=4;     b["1000baseT/Full"]=5
            b["10000baseT/Full"]=12
            b["2500baseX/Full"]=15
            b["1000baseKX/Full"]=17
            b["10000baseKX4/Full"]=18; b["10000baseKR/Full"]=19
            b["40000baseKR4/Full"]=23; b["40000baseCR4/Full"]=24
            b["40000baseSR4/Full"]=25; b["40000baseLR4/Full"]=26
            b["25000baseCR/Full"]=31
            b["25000baseKR/Full"]=32;  b["25000baseSR/Full"]=33
            b["50000baseCR2/Full"]=34; b["50000baseKR2/Full"]=35
            b["100000baseKR4/Full"]=36; b["100000baseSR4/Full"]=37
            b["100000baseCR4/Full"]=38
            b["1000baseX/Full"]=41
            b["10000baseCR/Full"]=42;  b["10000baseSR/Full"]=43
            b["10000baseLR/Full"]=44;  b["10000baseLRM/Full"]=45
            b["10000baseER/Full"]=46
            b["2500baseT/Full"]=47;    b["5000baseT/Full"]=48
            lo = 0; hi = 0
        }
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if ($0 in b) {
                bit = b[$0]
                if (bit < 32) lo += 2^bit
                else hi += 2^(bit-32)
            }
        }
        END {
            if (hi > 0) printf "0x%x%08x\n", hi, lo
            else if (lo > 0) printf "0x%x\n", lo
        }'
}
