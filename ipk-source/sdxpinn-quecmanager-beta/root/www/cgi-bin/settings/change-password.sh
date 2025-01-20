#!/bin/sh

# Set Content-Type for CGI script
echo "Content-type: application/json"
echo ""

# Read POST data
read -r POST_DATA

# Debug log for generated hash
DEBUG_LOG="/tmp/password_change.log"

# Extract the passwords from POST data (URL encoded)
USER="root"
OLD_PASSWORD=$(echo "$POST_DATA" | grep -o 'oldPassword=[^&]*' | cut -d= -f2-)
NEW_PASSWORD=$(echo "$POST_DATA" | grep -o 'newPassword=[^&]*' | cut -d= -f2-)

# URL-decode the passwords (replace + with space and decode %XX)
urldecode() {
    local encoded="${1//+/ }"
    printf '%b' "${encoded//%/\\x}"
}

OLD_PASSWORD=$(urldecode "$OLD_PASSWORD")
NEW_PASSWORD=$(urldecode "$NEW_PASSWORD")

# Basic validation to reject & and $ characters
if echo "$OLD_PASSWORD$NEW_PASSWORD" | grep -q '[&$]'; then
    echo '{"state":"failed","message":"Password contains forbidden characters (& or $)"}'
    exit 1
fi

# Extract the hashed password from /etc/shadow for the specified user
USER_SHADOW_ENTRY=$(grep "^$USER:" /etc/shadow)

if [ -z "$USER_SHADOW_ENTRY" ]; then
    echo '{"state":"failed","message":"User not found"}'
    exit 1
fi

# Extract the password hash (second field, colon-separated)
USER_HASH=$(echo "$USER_SHADOW_ENTRY" | cut -d: -f2)

# Extract the salt (MD5 uses the $1$ prefix followed by the salt)
SALT=$(echo "$USER_HASH" | cut -d'$' -f3)

# Generate hash from old password using the same salt
OLD_GENERATED_HASH=$(printf '%s' "$OLD_PASSWORD" | openssl passwd -1 -salt "$SALT" -stdin)

# Verify old password
if [ "$OLD_GENERATED_HASH" != "$USER_HASH" ]; then
    echo '{"state":"failed","message":"Current password is incorrect"}'
    exit 1
fi

# Create a temporary file for the new password
PASS_FILE=$(mktemp)
chmod 600 "$PASS_FILE"

# Write the new password twice (for confirmation)
printf '%s\n%s\n' "$NEW_PASSWORD" "$NEW_PASSWORD" > "$PASS_FILE"

# Change password using passwd command
ERROR_OUTPUT=$(passwd "$USER" < "$PASS_FILE" 2>&1)
RESULT=$?

# Log the operation
echo "Password change attempt. Result: $RESULT. Time: $(date)" >> "$DEBUG_LOG"
if [ $RESULT -ne 0 ]; then
    echo "Error output: $ERROR_OUTPUT" >> "$DEBUG_LOG"
fi

# Clean up
rm -f "$PASS_FILE"

# Return result
if [ $RESULT -eq 0 ]; then
    echo '{"state":"success","message":"Password changed successfully"}'
else
    echo '{"state":"failed","message":"Failed to change password"}'
fi