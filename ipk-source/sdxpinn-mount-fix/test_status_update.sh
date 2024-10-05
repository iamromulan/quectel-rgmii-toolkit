#!/bin/ash

# Function to update the status file with a properly formatted entry
add_to_status_file() {
    local bundled_package_name="$1"
    local version="$2"
    local depends="$3"
    local arch="$4"
    local installed_time="$5"

    # Status file location
    local status_file="/usr/lib/opkg/status"

    # Debugging: Output the details of the package being added
    echo "Adding package: $bundled_package_name"
    echo "Version: $version"
    echo "Depends: $depends"
    echo "Architecture: $arch"
    echo "Installed-Time: $installed_time"

    # Check if the package already exists in the status file
    if grep -q "Package: $bundled_package_name" "$status_file"; then
        echo "Removing old entry for $bundled_package_name from $status_file"
        sed -i "/Package: $bundled_package_name/,/^$/d" "$status_file"
    else
        echo "No existing entry for $bundled_package_name found. Adding new entry."
    fi

    # Append the new formatted entry to the status file
    echo "Appending new entry for $bundled_package_name to $status_file"
    cat << EOF >> "$status_file"
Package: $bundled_package_name
Version: $version
Depends: $depends
Status: install user installed
Architecture: $arch
Installed-Time: $installed_time

EOF

    # Verification: Check if the package was added correctly
    if grep -q "Package: $bundled_package_name" "$status_file"; then
        echo "Successfully added $bundled_package_name to $status_file."
    else
        echo "Failed to add $bundled_package_name to $status_file."
    fi
}

# Example usage: adding `libinotifytools` and `inotifywait` with dummy values
add_to_status_file "libinotifytools" "3.20.11.0-1" "libc" "aarch64_cortex-a53" "315965672"
add_to_status_file "inotifywait" "3.20.11.0-1" "libc, libinotifytools" "aarch64_cortex-a53" "315965672"

# Output the entire status file for review
echo "Current status file:"
cat /usr/lib/opkg/status

echo "Status file update completed."
