#!/bin/ash

# Function to update the status file with a properly formatted entry
add_to_status_file() {
    local package_name="$1"
    local version="$2"
    local depends="$3"
    local arch="$4"
    local installed_time="$5"

    # Status file location
    local status_file="/usr/lib/opkg/status"

    # Check if the package already exists and remove the old entry
    if grep -q "Package: $package_name" "$status_file"; then
        echo "Removing old entry for $package_name"
        sed -i "/Package: $package_name/,/^$/d" "$status_file"
    fi

    # Append the new formatted entry
    echo "Adding new entry for $package_name to $status_file"
    cat << EOF >> "$status_file"
Package: $package_name
Version: $version
Depends: $depends
Status: install user installed
Architecture: $arch
Installed-Time: $installed_time

EOF
}

# Example usage: adding `libinotifytools` and `inotifywait` with dummy values
add_to_status_file "libinotifytools" "3.20.11.0-1" "libc" "aarch64_cortex-a53" "315965672"
add_to_status_file "inotifywait" "3.20.11.0-1" "libc, libinotifytools" "aarch64_cortex-a53" "315965672"

echo "Status file updated!"
