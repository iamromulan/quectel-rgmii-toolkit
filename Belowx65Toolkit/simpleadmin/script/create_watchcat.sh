#!/bin/sh

# Function to create and run the Watchcat script
create_and_run_watchcat_script() {
    local ip=$1
    local timeout=$2
    local failure_count=$3
    local script_path="/usrdata/simpleadmin/script/watchcat.sh"

    # Create the script with the watchcat logic
    sudo cat << EOF > $script_path
#!/bin/sh

failures=0

while :; do
    if ping -c 1 $ip > /dev/null 2>&1; then
        failures=0
    else
        failures=\$((failures + 1))
        if [ "\$failures" -ge "$failure_count" ]; then
            echo "Rebooting system due to \$failures consecutive ping failures."
            /sbin/reboot
            exit 0
        fi
    fi
    sleep $timeout
done
EOF

    # Make the watchcat script executable
    chmod +x $script_path

    # Create a JSON to be fetched later
    echo "{\"enabled\": true, \"track_ip\": \"$ip\", \"ping_timeout\": $timeout, \"ping_failure_count\": $failure_count}" > /usrdata/simpleadmin/script/watchcat.json

    # Check if the script was created successfully
    if [ -f "$script_path" ]; then
        # Make the script executable
        chmod +x "$script_path"

        # Run the script in the background
        # nohup /bin/sh "$script_path" &
        /bin/sh "$script_path" &

        echo "Watchcat script created and running."
    else
        echo "Failed to create the Watchcat script."
        echo "Please check the script path: $script_path"
    fi
}

# Check if the script is called with the required parameters
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <IP> <timeout> <failure_count>"
    exit 1
fi

# Call the function with the provided arguments
create_and_run_watchcat_script "$1" "$2" "$3"