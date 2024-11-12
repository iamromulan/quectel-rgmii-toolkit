#!/bin/bash

# Check if the script is run as root. If not, rerun with sudo.
if [ "$(id -u)" -ne 0 ]; then
    echo "Script is not running as root. Re-executing with sudo..."
    exec sudo "$0" "$@"
fi

# Define Constants
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

# Iterate over each .ipk file in the current directory
for ipk_file in *.ipk; do
    # Extract package name, version, and architecture from the filename
    pkg_name_version_arch=$(echo "$ipk_file" | sed -E 's/.ipk$//')
    pkg_name=$(echo "$pkg_name_version_arch" | cut -d '_' -f 1)
    version=$(echo "$pkg_name_version_arch" | cut -d '_' -f 2)
    arch=$(echo "$pkg_name_version_arch" | cut -d '_' -f 3-)

    # Find the package entry in the Packages file
    pkg_start_line=$(grep -n "^Package: $pkg_name$" "$PACKAGES" | cut -d ':' -f 1)

    if [ -z "$pkg_start_line" ]; then
        echo "Package $pkg_name not found in $PACKAGES. Adding as new entry..." | tee -a "$LOGFILE"
        
        # Calculate MD5 and size for the new package entry
        read current_md5 current_size < <(calculate_md5_and_size "$ipk_file")

        # Append a new package entry with placeholders to Packages
        {
            echo "Package: $pkg_name"
            echo "Version: $version"
            echo "Depends: libc"
            echo "Section: packages"
            echo "Architecture: $arch"
            echo "Maintainer: Placeholder"
            echo "MD5Sum: $current_md5"
            echo "Size: $current_size"
            echo "Filename: $ipk_file"
            echo "Source: Placeholder"
            echo "Description: Placeholder"
            echo "License: Placeholder"
            echo ""
        } >> "$PACKAGES"

        continue
    fi

    # Find the end of the package entry (two consecutive empty lines)
    pkg_end_line=$(sed -n "$pkg_start_line,\$p" "$PACKAGES" | grep -n -m 1 -A 1 '^$' | tail -1 | cut -d '-' -f 1)
    pkg_end_line=$((pkg_start_line + pkg_end_line - 1))

    # Extract existing package details
    pkg_version=$(sed -n "${pkg_start_line},${pkg_end_line}p" "$PACKAGES" | grep "^Version:" | awk '{print $2}')
    pkg_md5sum=$(sed -n "${pkg_start_line},${pkg_end_line}p" "$PACKAGES" | grep "^MD5Sum:" | awk '{print $2}')
    pkg_size=$(sed -n "${pkg_start_line},${pkg_end_line}p" "$PACKAGES" | grep "^Size:" | awk '{print $2}')

    # Get the current MD5 and size for the .ipk file
    read current_md5 current_size < <(calculate_md5_and_size "$ipk_file")

    # Check if the version, MD5, or size differs and update if necessary
    if [ "$version" != "$pkg_version" ] || [ "$current_md5" != "$pkg_md5sum" ] || [ "$current_size" != "$pkg_size" ]; then
        echo "Updating package info for $pkg_name..." | tee -a "$LOGFILE"

        # Update the relevant fields in the Packages file
        sed -i "${pkg_start_line},${pkg_end_line}s/^Version: .*/Version: $version/" "$PACKAGES"
        sed -i "${pkg_start_line},${pkg_end_line}s/^MD5Sum: .*/MD5Sum: $current_md5/" "$PACKAGES"
        sed -i "${pkg_start_line},${pkg_end_line}s/^Size: .*/Size: $current_size/" "$PACKAGES"
        sed -i "${pkg_start_line},${pkg_end_line}s|^Filename: .*|Filename: $ipk_file|" "$PACKAGES"
        echo "Updated $pkg_name to version $version with MD5: $current_md5 and size: $current_size" | tee -a "$LOGFILE"
    else
        echo "No update needed for $pkg_name (version $pkg_version, MD5: $pkg_md5sum, size: $pkg_size)" | tee -a "$LOGFILE"
    fi
done

# Regenerate Packages.gz and sign with usign
if [ -f "$PACKAGESGZ" ]; then
    rm "$PACKAGESGZ"
fi
gzip -k "$PACKAGES"

if [ -f "$PACKAGESSIG" ]; then
    rm "$PACKAGESSIG"
fi
"$USIGN" -S -m "$PACKAGES" -s "$PRIVKEY"

echo "Package file and signature updated successfully." | tee -a "$LOGFILE"
echo "Package analysis completed - $(date)" | tee -a "$LOGFILE"

