#/bin/bash

# Check if the script is run as root. If not, rerun with sudo.
if [ "$(id -u)" -ne 0 ]; then
    echo "Script is not running as root. Re-executing with sudo..."
    exec sudo "$0" "$@"
fi

find ./ -type f -exec chmod +x {} \;
exit 0
