#!/bin/bash

# Check if the script is run as root. If not, rerun with sudo.
if [ "$(id -u)" -ne 0 ]; then
    echo "Script is not running as root. Re-executing with sudo..."
    exec sudo "$0" "$@"
fi

# Define Constants
IPK_SOURCE_DIR=../ipk-source
PACKAGES=./Packages
PACKAGESGZ=./Packages.gz
PACKAGESSIG=./Packages.sig
PUBLICKEY=./iamromulan-SDXPINN-repo.key
PRIVKEY=/home/iamromulan/Documents/GitHub/priv/iamromulan-SDXPINN-repo-private.key
USIGN=./usign_x64
LOGFILE=./Packages.log

# Start logging
echo "Starting package analysis - $(date)" > "$LOGFILE"

# Function to calculate MD5 and file size for a given .ipk file
calculate_md5_and_size() {
    local file=$1
    md5sum=$(md5sum "$file" | awk '{print $1}')
    filesize=$(stat -c%s "$file")
    echo "$md5sum $filesize"
}

# Function to parse control file
parse_control_file() {
    local control_file=$1
    local fields=(Package Version Depends Architecture Maintainer Source Description Section Conflicts License)
    declare -A control_data

    while IFS=':' read -r key value; do
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        if [[ " ${fields[*]} " == *" $key "* ]]; then
            control_data["$key"]="$value"
        fi
    done < "$control_file"

    echo "${control_data[@]}"
}

# Scan ipk-source directory and process packages
for pkg_dir in "$IPK_SOURCE_DIR"/*; do
    pkg_name=$(basename "$pkg_dir")
    if [[ "$pkg_name" =~ _ ]]; then
        pkg_arch=$(echo "$pkg_name" | awk -F'_' '{print $2}')
        pkg_name=$(echo "$pkg_name" | awk -F'_' '{print $1}')
    else
        pkg_arch="all"
    fi

    control_file="$pkg_dir/CONTROL/control"
    ipk_file="./${pkg_name}_*_${pkg_arch}.ipk"

    # Check if control file exists
    if [[ ! -f "$control_file" ]]; then
        echo "Skipping $pkg_name (missing control file)" | tee -a "$LOGFILE"
        continue
    fi

    # Match the .ipk file
    ipk_file=$(ls ./"${pkg_name}"_*_"${pkg_arch}".ipk 2>/dev/null)
    if [[ -z "$ipk_file" ]]; then
        echo "Skipping $pkg_name (missing .ipk file)" | tee -a "$LOGFILE"
        continue
    fi

    # Parse control file
    read -r -a control_data <<< "$(parse_control_file "$control_file")"

    # Calculate MD5 and size
    read current_md5 current_size < <(calculate_md5_and_size "$ipk_file")

    # Check if package exists in Packages file
    pkg_start_line=$(grep -n "^Package: ${control_data[Package]}$" "$PACKAGES" | cut -d ':' -f 1)

    if [ -z "$pkg_start_line" ]; then
        echo "Adding new package ${control_data[Package]}..." | tee -a "$LOGFILE"

        # Append new entry to Packages file
        {
            for key in "${!control_data[@]}"; do
                echo "$key: ${control_data[$key]}"
            done
            echo "MD5Sum: $current_md5"
            echo "Size: $current_size"
            echo "Filename: $ipk_file"
            echo ""
        } >> "$PACKAGES"

        continue
    fi

    # Update existing package entry if needed
    pkg_end_line=$(sed -n "$pkg_start_line,\$p" "$PACKAGES" | grep -n -m 1 -A 1 '^$' | tail -1 | cut -d '-' -f 1)
    pkg_end_line=$((pkg_start_line + pkg_end_line - 1))

    for key in "${!control_data[@]}"; do
        existing_value=$(sed -n "${pkg_start_line},${pkg_end_line}p" "$PACKAGES" | grep "^$key:" | awk -F': ' '{print $2}')
        if [[ "${control_data[$key]}" != "$existing_value" ]]; then
            echo "Updating $key for ${control_data[Package]}..." | tee -a "$LOGFILE"
            sed -i "${pkg_start_line},${pkg_end_line}s/^$key: .*/$key: ${control_data[$key]}/" "$PACKAGES"
        fi
    done

    # Update MD5 and size if different
    existing_md5=$(sed -n "${pkg_start_line},${pkg_end_line}p" "$PACKAGES" | grep "^MD5Sum:" | awk '{print $2}')
    existing_size=$(sed -n "${pkg_start_line},${pkg_end_line}p" "$PACKAGES" | grep "^Size:" | awk '{print $2}')

    if [[ "$current_md5" != "$existing_md5" ]] || [[ "$current_size" != "$existing_size" ]]; then
        echo "Updating MD5 and size for ${control_data[Package]}..." | tee -a "$LOGFILE"
        sed -i "${pkg_start_line},${pkg_end_line}s/^MD5Sum: .*/MD5Sum: $current_md5/" "$PACKAGES"
        sed -i "${pkg_start_line},${pkg_end_line}s/^Size: .*/Size: $current_size/" "$PACKAGES"
    fi
done

# Remove packages not in ipk-source
grep "^Package: " "$PACKAGES" | awk '{print $2}' | while read -r pkg_name; do
    if [[ ! -d "$IPK_SOURCE_DIR/$pkg_name"* ]]; then
        echo "Removing orphaned package $pkg_name from Packages file..." | tee -a "$LOGFILE"
        sed -i "/^Package: $pkg_name$/,/^$/d" "$PACKAGES"
    fi
done

# Regenerate Packages.gz and sign with usign
gzip -k "$PACKAGES"
"$USIGN" -S -m "$PACKAGES" -s "$PRIVKEY"

echo "Package file and signature updated successfully." | tee -a "$LOGFILE"
echo "Package analysis completed - $(date)" | tee -a "$LOGFILE"

