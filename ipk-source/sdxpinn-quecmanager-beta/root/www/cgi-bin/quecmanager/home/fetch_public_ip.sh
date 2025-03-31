#!/bin/sh

# Path: /www/cgi-bin/quecmanager

# Set JSON content type
echo "Content-Type: application/json"
echo ""

# Function to fetch IP with validation
fetch_ip() {
  SERVICES="$1"
  PATTERN="$2"
  
  for service in $SERVICES; do
    ip=$(
      curl -s "$service" 2>/dev/null || \
      wget -qO- "$service" 2>/dev/null || \
      uclient-fetch -qO- "$service" 2>/dev/null
    )
    # Validate against IP regex
    if echo "$ip" | grep -qE "$PATTERN"; then
      echo "$ip"
      return 0
    fi
  done
  echo "null"
}

# Services for IPv4 (ordered by reliability)
IPV4_SERVICES="
  https://v4.icanhazip.com
  https://api.ipify.org
  https://ipv4.ident.me
"

# Services for IPv6 (ordered by reliability)
IPV6_SERVICES="
  https://v6.icanhazip.com
  https://api6.ipify.org
  https://ipv6.ident.me
"

# Fetch IPv4 and IPv6
PUBLIC_IPV4=$(fetch_ip "$IPV4_SERVICES" '^([0-9]{1,3}\.){3}[0-9]{1,3}$')
PUBLIC_IPV6=$(fetch_ip "$IPV6_SERVICES" '^([a-f0-9:]+:+)+[a-f0-9]+$')

# Output JSON
echo "{\"public_ipv4\": \"$PUBLIC_IPV4\", \"public_ipv6\": \"$PUBLIC_IPV6\"}"