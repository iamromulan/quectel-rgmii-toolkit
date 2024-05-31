#!/bin/sh

# Function to remove the Watchcat script and JSON file
remove_watchcat_script() {
    local script_path="/usrdata/simpleadmin/script/watchcat.sh"
    local json_path="/usrdata/simpleadmin/script/watchcat.json"

    # Mount as read-write
    mount -o remount,rw /

    # Remove the watchcat script if it exists
    if [ -f "$script_path" ]; then
        rm "$script_path"
        echo "Removed $script_path"
    else
        echo "$script_path does not exist"
    fi

    # Remove the JSON file if it exists
    if [ -f "$json_path" ]; then
        rm "$json_path"
        echo "Removed $json_path"
    else
        echo "$json_path does not exist"
    fi

    # Mount as read-only
    mount -o remount,ro /
}

# Call the function to remove the scripts
remove_watchcat_script