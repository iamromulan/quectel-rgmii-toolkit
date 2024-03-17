#!/bin/bash
# sarav (hello@grity.com)
# convert key=value to json
# Created at Gritfy ( Devops Junction )
# Updated by: dr-dolomite to make it more robust since it was failing on some casess

file_name="$1"

echo "{"
last_line=$(wc -l < "$file_name")

while IFS='=' read -r key value || [[ -n "$key" ]]; do
    # Skip empty lines and comments
    if [[ -z "$key" || "$key" == \#* ]]; then
        continue
    fi

    # Trim leading and trailing whitespace from key and value
    key=$(echo "$key" | awk '{$1=$1};1')
    value=$(echo "$value" | awk '{$1=$1};1')

    # Check if value includes double quotes inside it like: "value,"value"". If there is, remove the inner double quotes.
    if [[ "$value" == *\"* ]]; then
        value=$(echo "$value" | sed 's/\"//g')
        # enclose the value in double quotes again
        value="\"$value\""
    fi

    # Print key-value pair in JSON format without surrounding double quotes on value
    printf ' "%s" : %s' "$key" "$value"

    # Check if not the last line, add comma
    if [ $((++current_line)) -lt "$last_line" ]; then
        printf ','
    fi

    printf '\n'
done < "$file_name"

echo "}"