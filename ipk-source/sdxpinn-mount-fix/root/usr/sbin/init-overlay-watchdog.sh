#!/bin/ash

# Paths to monitor and synchronize
WATCH_DIR="/etc/rc.d"
TARGET_DIR1="/real_rootfs/etc/rc.d"
TARGET_DIR2="/usrdata/etc/rc.d"
LOG_FILE="/tmp/init-overlay-watchdog.log"

# Function to synchronize init scripts
synchronize_init_scripts() {
    # Ensure /real_rootfs is writable for updates
    mount -o remount,rw /real_rootfs

    # Synchronize with TARGET_DIR1
    echo "Synchronizing $WATCH_DIR with $TARGET_DIR1..."
    for link in "$WATCH_DIR"/*; do
        if [ -L "$link" ]; then
            link_name=$(basename "$link")
            if [ ! -e "$TARGET_DIR1/$link_name" ] || [ "$link" -nt "$TARGET_DIR1/$link_name" ]; then
                cp -af "$link" "$TARGET_DIR1/$link_name"
            fi
        fi
    done

    for link in "$TARGET_DIR1"/*; do
        if [ -L "$link" ]; then
            link_name=$(basename "$link")
            if [ ! -e "$WATCH_DIR/$link_name" ]; then
                rm -f "$TARGET_DIR1/$link_name"
            fi
        fi
    done

    # Synchronize with TARGET_DIR2 if /usrdata exists
    if [ -d "/usrdata" ]; then
        echo "Synchronizing $WATCH_DIR with $TARGET_DIR2..."
        for link in "$WATCH_DIR"/*; do
            if [ -L "$link" ]; then
                link_name=$(basename "$link")
                if [ ! -e "$TARGET_DIR2/$link_name" ] || [ "$link" -nt "$TARGET_DIR2/$link_name" ]; then
                    cp -af "$link" "$TARGET_DIR2/$link_name"
                fi
            fi
        done

        for link in "$TARGET_DIR2"/*; do
            if [ -L "$link" ]; then
                link_name=$(basename "$link")
                if [ ! -e "$WATCH_DIR/$link_name" ]; then
                    rm -f "$TARGET_DIR2/$link_name"
                fi
            fi
        done
    fi

    # Restore /real_rootfs to read-only
    mount -o remount,ro /real_rootfs
}

# Initialize log
rm -f "$LOG_FILE" >/dev/null 2>&1
touch "$LOG_FILE"

# Redirect all output (stdout and stderr) to the log file
exec >>"$LOG_FILE" 2>&1

# Initial synchronization
synchronize_init_scripts

# Monitor WATCH_DIR for changes using inotifywait
while true; do
    inotifywait -e create,delete,modify,move "$WATCH_DIR"
    synchronize_init_scripts
done

