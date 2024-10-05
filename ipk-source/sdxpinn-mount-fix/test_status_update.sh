#!/bin/ash

# Define the path to the status file
STATUS_FILE="/usr/lib/opkg/status"

# Define the control files for bundled packages
CONTROL_FILES="/usr/lib/opkg/info/libinotifytools.control /usr/lib/opkg/info/inotifywait.control"

# Function to update the status file for a given control file
update_status_file() {
    local control_file="$1"
    local bundled_package_name=$(basename "$control_file" .control)
    
    if [ ! -f "$control_file" ]; then
        echo "Error: Control file not found for $bundled_package_name at $control_file"
        return 1
    fi

    # Append a newline and then add the control file contents to the status file
    echo "" >> "$STATUS_FILE"
    echo "Adding entry for $bundled_package_name to $STATUS_FILE"
    
    {
        # Read the control file contents
        cat "$control_file"
        
        # Add a 'Status' line indicating the package is 'user installed'
        echo "Status: install user installed"

        # Add the architecture (modify this as per your system's architecture if needed)
        echo "Architecture: aarch64_cortex-a53"

        # Timestamp for when the package was installed
        echo "Installed-Time: $(date +%s)"
    } >> "$STATUS_FILE"

    echo "Successfully added $bundled_package_name to $STATUS_FILE"
}

# Iterate through each control file and update the status file
for control_file in $CONTROL_FILES; do
    update_status_file "$control_file"
done

# Output the status file content for verification
echo "Contents of $STATUS_FILE:"
grep -A 5 -E "Package: (libinotifytools|inotifywait)" "$STATUS_FILE"

exit 0
