#!/bin/sh

# Set Content-Type for CGI script
echo "Content-type: application/json"
echo ""

# Read POST data
read POST_DATA

# Debug log
DEBUG_LOG="/tmp/password_change.log"

# Extract the passwords from POST data
OLD_PASSWORD=$(echo "$POST_DATA" | sed -n 's/^.*oldPassword=\([^&]*\).*$/\1/p')
NEW_PASSWORD=$(echo "$POST_DATA" | sed -n 's/^.*newPassword=\([^&]*\).*$/\1/p')

# URL-decode the passwords
OLD_PASSWORD=$(echo "$OLD_PASSWORD" | sed 's/+/ /g;s/%\(..\)/\\x\1/g' | xargs -0 printf "%b")
NEW_PASSWORD=$(echo "$NEW_PASSWORD" | sed 's/+/ /g;s/%\(..\)/\\x\1/g' | xargs -0 printf "%b")

# User to change password for
USER="root"

# Verify old password first
USER_SHADOW_ENTRY=$(grep "^$USER:" /etc/shadow)
if [ -z "$USER_SHADOW_ENTRY" ]; then
    echo '{"state":"failed", "message":"User not found"}'
    exit 1
fi

# Extract current password hash and salt
USER_HASH=$(echo "$USER_SHADOW_ENTRY" | cut -d: -f2)
SALT=$(echo "$USER_HASH" | cut -d'$' -f3)

# Generate hash from old password
OLD_GENERATED_HASH=$(echo "$OLD_PASSWORD" | openssl passwd -1 -salt "$SALT" -stdin)

# Verify old password
if [ "$OLD_GENERATED_HASH" != "$USER_HASH" ]; then
    echo '{"state":"failed", "message":"Current password is incorrect"}'
    exit 1
fi

# Change password using passwd command
# We need to pass both the new password and its confirmation
(echo "$NEW_PASSWORD"; echo "$NEW_PASSWORD") | passwd $USER 2>> $DEBUG_LOG

if [ $? -eq 0 ]; then
    echo '{"state":"success", "message":"Password changed successfully"}'
else
    echo '{"state":"failed", "message":"Failed to change password"}'
fi