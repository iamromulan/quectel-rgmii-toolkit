#!/bin/ash

# Paths to monitor and synchronize
WATCH_DIR="/etc/rc.d"
TARGET_DIR="/real_rootfs/etc/rc.d"

# Function to synchronize init scripts
synchronize_init_scripts() {
    mount -o remount,rw /real_rootfs
    # Copy new or updated symlinks from WATCH_DIR to TARGET_DIR
    for link in "$WATCH_DIR"/*; do
        if [ -L "$link" ]; then
            link_name=$(basename "$link")
            if [ ! -e "$TARGET_DIR/$link_name" ] || [ "$link" -nt "$TARGET_DIR/$link_name" ]; then
                cp -af "$link" "$TARGET_DIR/$link_name"
            fi
        fi
    done

    # Remove symlinks in TARGET_DIR that no longer exist in WATCH_DIR
    for link in "$TARGET_DIR"/*; do
        if [ -L "$link" ]; then
            link_name=$(basename "$link")
            if [ ! -e "$WATCH_DIR/$link_name" ]; then
                rm -f "$TARGET_DIR/$link_name"
            fi
        fi
    done
    mount -o remount,ro /real_rootfs
}

# Initial synchronization
synchronize_init_scripts

# Monitor WATCH_DIR for changes using inotifywait
while true; do
    inotifywait -e create,delete,modify,move "$WATCH_DIR"
    synchronize_init_scripts
done
