#!/bin/sh

. /lib/functions.sh

LOG_TAG="autoupgrade"
LOG_FILE="/var/log/autoupgrade.log"

if command -v apk > /dev/null 2>&1; then
	PKG_MGR="apk"
else
	PKG_MGR="opkg"
fi

log_msg() {
	local level="$1"
	local msg="$2"
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
	logger -t "$LOG_TAG" -p "daemon.$level" "$msg"
	echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

pkg_update() {
	if [ "$PKG_MGR" = "apk" ]; then
		apk update "$@"
	else
		opkg update "$@"
	fi
}

pkg_check_upgradable() {
	local name="$1"
	if [ "$PKG_MGR" = "apk" ]; then
		apk list --upgradable 2>/dev/null | grep "^${name}-[0-9]"
	else
		opkg list-upgradable 2>/dev/null | grep "^${name} "
	fi
}

pkg_get_versions() {
	local line="$1"
	if [ "$PKG_MGR" = "apk" ]; then
		old_ver="$(echo "$line" | sed -n 's/.*{\([^ ]*\)}/\1/p')"
		new_ver="$(echo "$line" | awk '{print $1}' | sed 's/.*-//')"
	else
		old_ver="$(echo "$line" | awk '{print $3}')"
		new_ver="$(echo "$line" | awk '{print $5}')"
	fi
}

pkg_upgrade() {
	local name="$1"
	if [ "$PKG_MGR" = "apk" ]; then
		apk upgrade "$name"
	else
		opkg upgrade "$name"
	fi
}

config_load "autoupgrade"

enabled=""
retry_interval=""

config_get enabled settings enabled "0"
config_get retry_interval settings retry_interval "30"

if [ "$enabled" != "1" ]; then
	exit 0
fi

log_msg "info" "Starting scheduled upgrade check (package manager: $PKG_MGR)"

pkg_update > /tmp/autoupgrade-update.out 2>&1
rc=$?

if [ $rc -ne 0 ]; then
	log_msg "err" "$PKG_MGR update failed (exit $rc)"
	while IFS= read -r line; do
		log_msg "err" "  $line"
	done < /tmp/autoupgrade-update.out
	rm -f /tmp/autoupgrade-update.out

	if [ "$retry_interval" -gt 0 ] 2>/dev/null; then
		log_msg "warning" "Will retry in $retry_interval minutes"
		sleep "$((retry_interval * 60))"
		exec "$0"
	fi
	exit 1
fi

rm -f /tmp/autoupgrade-update.out
log_msg "info" "Package lists updated successfully"

upgrade_count=0
fail_count=0
skip_count=0

handle_package() {
	local cfg="$1"
	local name=""
	config_get name "$cfg" name ""

	[ -z "$name" ] && return

	local avail
	avail="$(pkg_check_upgradable "$name")"

	if [ -z "$avail" ]; then
		log_msg "info" "$name: already up to date"
		skip_count=$((skip_count + 1))
		return
	fi

	local old_ver new_ver
	pkg_get_versions "$avail"
	log_msg "info" "$name: upgrading $old_ver -> $new_ver"

	pkg_upgrade "$name" > /tmp/autoupgrade-pkg.out 2>&1
	rc=$?

	if [ $rc -eq 0 ]; then
		log_msg "info" "$name: upgrade successful"
		upgrade_count=$((upgrade_count + 1))
	else
		log_msg "err" "$name: upgrade failed (exit $rc)"
		while IFS= read -r line; do
			log_msg "err" "  $name: $line"
		done < /tmp/autoupgrade-pkg.out
		fail_count=$((fail_count + 1))
	fi

	rm -f /tmp/autoupgrade-pkg.out
}

config_foreach handle_package package

log_msg "info" "Upgrade check complete: $upgrade_count upgraded, $skip_count up-to-date, $fail_count failed"

config_get interval settings interval "daily"
if [ "$interval" = "monthly" ]; then
	AUTOUPGRADE_NEXT_MONTH=1 /etc/init.d/autoupgrade reload 2>/dev/null
fi
