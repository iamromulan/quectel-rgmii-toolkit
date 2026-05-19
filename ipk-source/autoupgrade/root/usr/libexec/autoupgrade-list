#!/bin/sh
if command -v apk > /dev/null 2>&1; then
	apk list --installed 2>/dev/null | sed 's/-\([0-9][^ ]*\) .*/\t\1/'
else
	opkg list-installed 2>/dev/null | awk '{ print $1 "\t" $3 }'
fi
