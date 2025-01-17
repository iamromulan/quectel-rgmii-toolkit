#!/bin/sh

# Set the content type to JSON
echo "Content-Type: application/json"
echo ""

# Get the IP address of the br-lan interface
brlan_ip=$(ip route | grep 'dev br-lan proto kernel scope link' | awk '{print $9}')

# Output the IP in JSON format
echo "{\"br_lan_ip\": \"$brlan_ip\"}"