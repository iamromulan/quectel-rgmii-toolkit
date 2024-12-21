#!/bin/sh

# Set content type to JSON
echo "Content-Type: application/json"
echo

# Read the JSON file and get only the last entry using jq
jq 'last' /www/signal_graphs/data_usage.json