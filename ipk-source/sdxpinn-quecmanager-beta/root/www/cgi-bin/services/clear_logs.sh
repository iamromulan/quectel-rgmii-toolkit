#!/bin/sh

# Script path
SCRIPT_PATH=$(readlink -f "$0")
# Fix the spacing in the cron line to ensure exactly 5 fields
CRON_LINE="0 0 * * * $SCRIPT_PATH"

# Install crontab if not already present
if ! crontab -l | grep -Fq "$SCRIPT_PATH"; then
    # Get existing crontab - ensuring clean formatting
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" || true; echo "$CRON_LINE") | crontab -

    if [ $? -eq 0 ]; then
        logger -t log_cleanup "Successfully installed crontab job"
    else
        logger -t log_cleanup "Failed to install crontab job"
        exit 1
    fi
fi

# Clean specified log files using echo redirection
echo "" > /tmp/apn_profiles.log
echo "" > /tmp/imei_profiles.log
echo "" > /var/log/at_commands.log

# Add error handling
if [ $? -ne 0 ]; then
    logger -t log_cleanup "Failed to clean one or more log files"
    exit 1
fi

logger -t log_cleanup "Successfully cleaned log files"