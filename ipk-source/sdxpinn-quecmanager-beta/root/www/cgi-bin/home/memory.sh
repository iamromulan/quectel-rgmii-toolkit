#!/bin/sh

# Set the content type to JSON
echo "Content-Type: application/json"
echo ""

# Run free command and capture the output, using -b for bytes
free_output=$(free -b)

# Extract memory information using awk
# Skip the header, take the Mem: line, and extract total, used, and available
memory_info=$(echo "$free_output" | awk '/Mem:/ {print "{\"total\": " $2 ", \"used\": " $3 ", \"available\": " $7 "}"}')

# Output the JSON
echo "$memory_info"