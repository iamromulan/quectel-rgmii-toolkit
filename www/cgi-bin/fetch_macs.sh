#!/bin/sh
echo "Content-type: application/json"
echo ""

# Create a temporary file to store the processed data
temp_file=$(mktemp)

# Process ARP entries and store in temporary file
arp -a | while IFS= read -r line; do
    if [ -n "$line" ]; then
        # Extract hostname (or IP if hostname is "?"), IP, and MAC
        hostname=$(echo "$line" | awk '{print $1}')
        ip=$(echo "$line" | awk -F '[()]' '{print $2}')
        mac=$(echo "$line" | awk '{print $4}')
        
        # Skip entries without valid MAC addresses
        if [ "$mac" = "<incomplete>" ]; then
            continue
        fi

        # If hostname is "?", use the IP address instead
        if [ "$hostname" = "?" ]; then
            hostname="$ip"
        fi

        # Store each entry in the temp file
        echo "$hostname:$ip:$mac" >> "$temp_file"
    fi
done

# Initialize JSON array
echo -n "["

# Process the temporary file to create JSON
first=true
while IFS=: read -r hostname ip mac; do
    if [ "$first" = true ]; then
        first=false
    else
        echo -n ","
    fi
    echo -n "{\"hostname\":\"$hostname\",\"ip\":\"$ip\",\"mac\":\"$mac\"}"
done < "$temp_file"

# Close the JSON array
echo "]"

# Clean up
rm -f "$temp_file"