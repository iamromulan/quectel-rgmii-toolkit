#!/bin/sh

# Set Content-Type for CGI script
echo "Content-type: application/json"
echo ""

# Read POST data
read POST_DATA

# Extract the password from POST data (URL encoded)
USER="root"
INPUT_PASSWORD=$(echo "$POST_DATA" | sed -n 's/^.*password=\([^&]*\).*$/\1/p')

# URL-decode the password (replace + with space and decode %XX)
INPUT_PASSWORD=$(echo "$INPUT_PASSWORD" | sed 's/+/ /g;s/%\(..\)/\\x\1/g' | xargs -0 printf "%b")

# Log received password for debugging (remove in production)
# echo "Received password: $INPUT_PASSWORD" >&2

# Extract the hashed password from /etc/shadow for the specified user
USER_SHADOW_ENTRY=$(grep "^$USER:" /etc/shadow)

if [ -z "$USER_SHADOW_ENTRY" ]; then
    echo '{"state":"failed", "message":"User not found"}'
    exit 1
fi

# Extract the password hash (it's the second field, colon-separated)
USER_HASH=$(echo "$USER_SHADOW_ENTRY" | cut -d: -f2)

# Extract the salt (MD5 uses the $1$ prefix followed by the salt)
SALT=$(echo "$USER_HASH" | cut -d'$' -f3)

# Generate a hash from the input password using the same salt
GENERATED_HASH=$(echo "$INPUT_PASSWORD" | openssl passwd -1 -salt "$SALT" -stdin)

# Log generated hash for debugging
echo "Generated hash: $GENERATED_HASH" >&2

# Compare the generated hash with the one in the shadow file
if [ "$GENERATED_HASH" = "$USER_HASH" ]; then
    echo '{"state":"success", "hashed_password":"'"$GENERATED_HASH"'"}'
else
    echo '{"state":"failed", "hashed_password":"'"$GENERATED_HASH"'"}'
fi
