#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# update.sh — CGI Endpoint: Software Update (GET + POST)
# =============================================================================
# GET:                   Check for updates via GitHub Releases API
# GET action=status:     Read update progress from status file
# POST action=download:  Stage a version (download + SHA-256 verify)
# POST action=install_staged: Install the staged tarball
# POST action=install:   Legacy one-step install (used by auto-updater)
# POST action=save_prerelease: Toggle pre-release preference
# POST action=save_auto_update: Configure auto-update schedule
#
# Config: UCI quecmanager.update.*
# State:  /tmp/qmanager_update.json, /tmp/qmanager_update.pid
#         /var/run/qmanager/update/staged.tar.gz + staged_version (root 0700)
#
# Endpoint: GET/POST /cgi-bin/quecmanager/system/update.sh
# =============================================================================

qlog_init "cgi_system_update"
cgi_headers
cgi_handle_options

# --- Configuration -----------------------------------------------------------

GITHUB_REPO="dr-dolomite/QManager"
VERSION_FILE="/etc/qmanager/VERSION"
UPDATES_DIR="/etc/qmanager/updates"
STATUS_FILE="/tmp/qmanager_update.json"
PID_FILE="/tmp/qmanager_update.pid"
UPDATER="/usr/bin/qmanager_update"
# Written by qmanager_update in a root-only dir (B4.1).
STAGED_TARBALL="/var/run/qmanager/update/staged.tar.gz"
STAGED_VERSION_FILE="/var/run/qmanager/update/staged_version"
# install.sh writes this before touching files and promotes it to VERSION on
# success, so a marker that outlives the installer means an interrupted install.
VERSION_PENDING="/etc/qmanager/VERSION.pending"
# qm_read_pid (also pulled in by cgi_auth.sh; explicit so the lock check never
# silently loses it).
[ -f /usr/lib/qmanager/safe_tmp.sh ] && . /usr/lib/qmanager/safe_tmp.sh

# --- Helpers -----------------------------------------------------------------

ensure_updater_executable() {
    if [ -x "$UPDATER" ]; then
        return 0
    fi

    if [ ! -f "$UPDATER" ]; then
        cgi_error "updater_missing" "Update worker not found at $UPDATER"
        return 1
    fi

    if [ -L "$UPDATER" ]; then
        cgi_error "updater_invalid_target" "Update worker path must not be a symlink"
        return 1
    fi

    chmod 755 "$UPDATER" 2>/dev/null || {
        cgi_error "updater_not_executable" "Cannot make update worker executable"
        return 1
    }

    return 0
}

# True when opkg owns this install (sdxpinn-qmanager ipk). See install.sh.
package_managed() {
    [ -f /usr/lib/opkg/info/sdxpinn-qmanager.control ]
}

get_current_version() {
    if [ -f "$VERSION_FILE" ]; then
        tr -d '[:space:]' < "$VERSION_FILE"
    else
        echo "0.0.0"
    fi
}

uci_update_get() {
    local val
    val=$(uci -q get "quecmanager.update.$1" 2>/dev/null)
    if [ -z "$val" ]; then echo "$2"; else echo "$val"; fi
}

ensure_update_config() {
    uci -q get quecmanager.update >/dev/null 2>&1 && return
    uci set quecmanager.update=update
    uci set quecmanager.update.include_prerelease=1
    uci set quecmanager.update.auto_update_enabled=0
    uci set quecmanager.update.auto_update_time=03:00
    uci commit quecmanager
}

strip_leading_zero() {
    local v
    v=$(echo "$1" | sed 's/^0*//')
    [ -z "$v" ] && v=0
    echo "$v"
}

# Check if an update process is already running
check_lock() {
    if [ -f "$PID_FILE" ]; then
        local pid
        # B4.1: only a root-owned pidfile naming a live updater counts.
        pid=$(qm_read_pid "$PID_FILE" qmanager_update 2>/dev/null)
        if [ -n "$pid" ]; then
            cgi_error "update_in_progress" "An update is already in progress"
            exit 0
        fi
        rm -f "$PID_FILE"
    fi
}

# Fetch URL to a file, capturing HTTP headers for rate-limit detection.
# curl-only — the installer guarantees curl is present.
http_api_fetch() {
    local url="$1" out_file="$2" header_file="$3" timeout="${4:-15}"

    if ! command -v curl >/dev/null 2>&1; then
        return 1
    fi

    curl -sSL \
        --max-time "$timeout" \
        --connect-timeout 10 \
        -o "$out_file" \
        -D "$header_file" \
        "$url" 2>/dev/null
}

# Semver comparison. Exit codes: 0 = $1 newer, 1 = same, 2 = $1 older
semver_compare() {
    local a="$1" b="$2"
    a="${a#v}"; b="${b#v}"
    local a_ver="${a%%-*}" a_pre="" b_ver="${b%%-*}" b_pre=""
    case "$a" in *-*) a_pre="${a#*-}" ;; esac
    case "$b" in *-*) b_pre="${b#*-}" ;; esac

    local a1 a2 a3 b1 b2 b3
    IFS='.' read a1 a2 a3 <<EOF
$a_ver
EOF
    IFS='.' read b1 b2 b3 <<EOF
$b_ver
EOF
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}

    [ "$a1" -gt "$b1" ] 2>/dev/null && return 0
    [ "$a1" -lt "$b1" ] 2>/dev/null && return 2
    [ "$a2" -gt "$b2" ] 2>/dev/null && return 0
    [ "$a2" -lt "$b2" ] 2>/dev/null && return 2
    [ "$a3" -gt "$b3" ] 2>/dev/null && return 0
    [ "$a3" -lt "$b3" ] 2>/dev/null && return 2

    # Equal major.minor.patch — no pre-release > any pre-release
    [ -z "$a_pre" ] && [ -n "$b_pre" ] && return 0
    [ -n "$a_pre" ] && [ -z "$b_pre" ] && return 2
    [ -z "$a_pre" ] && [ -z "$b_pre" ] && return 1

    # Both have pre-release — lexical comparison (POSIX: sort, no \> \< in [ ])
    if [ "$a_pre" != "$b_pre" ]; then
        _lesser=$(printf '%s\n%s\n' "$a_pre" "$b_pre" | sort | head -1)
        if [ "$_lesser" = "$a_pre" ]; then
            return 2  # a_pre is lexically lesser → a is older
        else
            return 0  # b_pre is lexically lesser → a is newer
        fi
    fi
    return 1
}

# =============================================================================
# GET — Check for updates / Read status
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    action=$(echo "$QUERY_STRING" | sed -n 's/.*action=\([^&]*\).*/\1/p')

    # --- Status polling ---
    if [ "$action" = "status" ]; then
        if [ -f "$STATUS_FILE" ]; then
            cat "$STATUS_FILE"
        else
            jq -n '{"status":"idle"}'
        fi
        exit 0
    fi

    # --- Update check ---
    qlog_info "Checking for updates"
    ensure_update_config

    current_version=$(get_current_version)
    include_prerelease=$(uci_update_get include_prerelease "1")
    auto_enabled=$(uci_update_get auto_update_enabled "0")
    auto_time=$(uci_update_get auto_update_time "03:00")

    # A package (ipk) install updates through opkg, so there is nothing to
    # check on GitHub and every tarball action below is refused.
    if package_managed; then
        jq -n \
            --arg cv "$current_version" \
            --argjson prerelease "$include_prerelease" \
            --arg auto_time "$auto_time" \
            '{
                success: true, current_version: $cv,
                latest_version: null, update_available: false,
                changelog: null, current_changelog: null,
                download_url: null, download_size: null,
                available_versions: [], download_state: null,
                include_prerelease: ($prerelease == 1),
                auto_update_enabled: false,
                auto_update_time: $auto_time,
                previous_install_failed: false,
                pending_version: null,
                check_error: null,
                managed_by: "opkg",
                package_name: "sdxpinn-qmanager"
            }'
        exit 0
    fi

    # Interrupted-install detection. A live updater owns the marker mid-install,
    # so only a marker with no updater behind it counts as a failure.
    pending_version=""
    if [ -f "$VERSION_PENDING" ] && [ -z "$(qm_read_pid "$PID_FILE" qmanager_update 2>/dev/null)" ]; then
        pending_version=$(tr -d '[:space:]' < "$VERSION_PENDING" 2>/dev/null)
    fi
    if [ -n "$pending_version" ]; then
        previous_install_failed="true"
    else
        previous_install_failed="false"
    fi

    # Query GitHub Releases API with header capture for rate-limit detection
    api_url="https://api.github.com/repos/$GITHUB_REPO/releases"
    # B4.1: private temp names; the release JSON picks the download URL.
    tmp_body=$(mktemp /tmp/qm_update_api_body.XXXXXX 2>/dev/null)
    tmp_headers=$(mktemp /tmp/qm_update_api_headers.XXXXXX 2>/dev/null)

    if [ -z "$tmp_body" ] || [ -z "$tmp_headers" ] || ! http_api_fetch "$api_url" "$tmp_body" "$tmp_headers"; then
        rm -f "$tmp_body" "$tmp_headers"
        jq -n \
            --arg cv "$current_version" \
            --argjson prerelease "$include_prerelease" \
            --arg auto_en "$auto_enabled" \
            --arg auto_time "$auto_time" \
            --argjson pif "$previous_install_failed" \
            --arg pv "$pending_version" \
            '{
                success: true, current_version: $cv,
                latest_version: null, update_available: false,
                changelog: null, current_changelog: null,
                download_url: null, download_size: null,
                available_versions: [], download_state: null,
                include_prerelease: ($prerelease == 1),
                auto_update_enabled: ($auto_en == "1"),
                auto_update_time: $auto_time,
                previous_install_failed: $pif,
                pending_version: (if $pv == "" then null else $pv end),
                check_error: "Unable to check for updates. Check your internet connection.",
                managed_by: "tarball"
            }'
        exit 0
    fi

    # Check for rate limiting (HTTP 403)
    if grep -qi "403 Forbidden\|HTTP/[0-9.]* 403" "$tmp_headers" 2>/dev/null; then
        # Try to parse reset time
        reset_ts=$(grep -i 'x-ratelimit-reset' "$tmp_headers" | sed 's/.*: *//;s/\r//' | head -1)
        wait_msg="Rate limit reached. Try again later."
        if [ -n "$reset_ts" ]; then
            now_ts=$(date +%s 2>/dev/null)
            if [ -n "$now_ts" ] && [ -n "$reset_ts" ] && [ "$reset_ts" -gt "$now_ts" ] 2>/dev/null; then
                wait_mins=$(( (reset_ts - now_ts + 59) / 60 ))
                wait_msg="Rate limit reached. Try again in ${wait_mins} minute(s)."
            fi
        fi
        rm -f "$tmp_body" "$tmp_headers"
        jq -n \
            --arg cv "$current_version" \
            --argjson prerelease "$include_prerelease" \
            --arg err "$wait_msg" \
            --arg auto_en "$auto_enabled" \
            --arg auto_time "$auto_time" \
            --argjson pif "$previous_install_failed" \
            --arg pv "$pending_version" \
            '{
                success: true, current_version: $cv,
                latest_version: null, update_available: false,
                changelog: null, current_changelog: null,
                download_url: null, download_size: null,
                available_versions: [], download_state: null,
                include_prerelease: ($prerelease == 1),
                auto_update_enabled: ($auto_en == "1"),
                auto_update_time: $auto_time,
                previous_install_failed: $pif,
                pending_version: (if $pv == "" then null else $pv end),
                check_error: $err,
                managed_by: "tarball"
            }'
        exit 0
    fi

    api_response=$(cat "$tmp_body" 2>/dev/null)
    rm -f "$tmp_body" "$tmp_headers"

    # Filter by pre-release preference
    if [ "$include_prerelease" = "1" ]; then
        release_filter='.[0]'
    else
        release_filter='[ .[] | select(.prerelease == false) ] | .[0]'
    fi

    # Extract release info
    latest_tag=$(echo "$api_response" | jq -r "$release_filter | .tag_name // empty")
    changelog=$(echo "$api_response" | jq -r "$release_filter | .body // empty")

    # Extract current version's changelog from the same API response
    current_changelog=""
    if [ -n "$current_version" ] && [ "$current_version" != "0.0.0" ]; then
        current_changelog=$(echo "$api_response" | jq -r \
            --arg cv "$current_version" \
            '[ .[] | select(.tag_name == $cv) ] | .[0].body // empty')
    fi

    # Detect staged download state
    download_state="null"
    staged_tarball="$STAGED_TARBALL"
    staged_version_file="$STAGED_VERSION_FILE"

    if [ -f "$PID_FILE" ]; then
        pid=$(qm_read_pid "$PID_FILE" qmanager_update 2>/dev/null)
        if [ -n "$pid" ] && [ -f "$STATUS_FILE" ]; then
            download_state=$(cat "$STATUS_FILE" 2>/dev/null)
        fi
    elif [ -f "$staged_tarball" ] && [ -f "$staged_version_file" ]; then
        staged_ver=$(cat "$staged_version_file" 2>/dev/null)
        staged_size=$(du -k "$staged_tarball" 2>/dev/null | awk '{printf "%.1f MB", $1/1024}')
        download_state=$(jq -n \
            --arg status "ready" \
            --arg version "$staged_ver" \
            --arg message "Download verified ($staged_size)" \
            --arg size "$staged_size" \
            '{status: $status, version: $version, message: $message, size: $size}')
    fi

    # Build available_versions list from API response
    available_versions=$(echo "$api_response" | jq \
        --arg cv "$current_version" \
        '[ .[] | {
            tag: .tag_name,
            has_assets: ((.assets | length) > 0),
            asset_size: (if (.assets | length) > 0 then
                (.assets[0].size / 1048576 * 10 | floor / 10 | tostring + " MB")
            else null end),
            is_current: (.tag_name == $cv)
        }]')

    # Download URL from GitHub Releases (curl handles redirects)
    download_url=""
    if [ -n "$latest_tag" ]; then
        download_url="https://github.com/${GITHUB_REPO}/releases/download/${latest_tag}/qmanager.tar.gz"
    fi
    download_size=""

    update_available="false"
    if [ -n "$latest_tag" ]; then
        semver_compare "$latest_tag" "$current_version"
        case $? in
            0) update_available="true" ;;
        esac
    fi

    jq -n \
        --arg cv "$current_version" \
        --arg lv "${latest_tag:-}" \
        --argjson ua "$update_available" \
        --arg cl "$changelog" \
        --arg ccl "$current_changelog" \
        --arg dl "${download_url:-}" \
        --arg ds "$download_size" \
        --argjson av "$available_versions" \
        --argjson ds_obj "$download_state" \
        --argjson prerelease "$include_prerelease" \
        --arg auto_en "$auto_enabled" \
        --arg auto_time "$auto_time" \
        --argjson pif "$previous_install_failed" \
        --arg pv "$pending_version" \
        '{
            success: true,
            current_version: $cv,
            latest_version: (if $lv == "" then null else $lv end),
            update_available: $ua,
            changelog: (if $cl == "" then null else $cl end),
            current_changelog: (if $ccl == "" then null else $ccl end),
            download_url: (if $dl == "" then null else $dl end),
            download_size: (if $ds == "" then null else $ds end),
            available_versions: $av,
            download_state: $ds_obj,
            include_prerelease: ($prerelease == 1),
            auto_update_enabled: ($auto_en == "1"),
            auto_update_time: $auto_time,
            previous_install_failed: $pif,
            pending_version: (if $pv == "" then null else $pv end),
            check_error: null,
            managed_by: "tarball"
        }'
    exit 0
fi

# =============================================================================
# POST — Install / Rollback / Save preferences
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty')
    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    case "$ACTION" in
        download|install_staged|install|rollback|save_auto_update)
            if package_managed; then
                cgi_error "package_managed" "QManager is installed as the sdxpinn-qmanager package; update it with opkg"
                exit 0
            fi
            ;;
    esac

    # --- Save pre-release preference ---
    if [ "$ACTION" = "save_prerelease" ]; then
        ensure_update_config
        enabled=$(printf '%s' "$POST_DATA" | jq -r '(.enabled) | if . == null then empty else tostring end')
        case "$enabled" in
            true)  uci set quecmanager.update.include_prerelease=1 ;;
            false) uci set quecmanager.update.include_prerelease=0 ;;
            *) cgi_error "invalid_value" "enabled must be true or false"; exit 0 ;;
        esac
        uci commit quecmanager
        cgi_success
        exit 0
    fi

    # --- Save auto-update preference ---
    if [ "$ACTION" = "save_auto_update" ]; then
        ensure_update_config
        enabled=$(printf '%s' "$POST_DATA" | jq -r '(.enabled) | if . == null then empty else tostring end')
        auto_time=$(printf '%s' "$POST_DATA" | jq -r '.time // empty')

        case "$enabled" in
            true|false) ;;
            *) cgi_error "invalid_value" "enabled must be true or false"; exit 0 ;;
        esac
        echo "$auto_time" | grep -qE '^[0-9]{2}:[0-9]{2}$' || {
            cgi_error "invalid_value" "time must be HH:MM format"; exit 0
        }

        case "$enabled" in
            true)  uci set quecmanager.update.auto_update_enabled=1 ;;
            false) uci set quecmanager.update.auto_update_enabled=0 ;;
        esac
        uci set quecmanager.update.auto_update_time="$auto_time"
        uci commit quecmanager

        # Manage crontab (same pattern as settings.sh scheduled reboot)
        CRON_MARKER="# qmanager_auto_update"
        AUTO_UPDATE_SCRIPT="/usr/bin/qmanager_auto_update"
        current_cron=$(crontab -l 2>/dev/null || true)
        filtered_cron=$(printf '%s\n' "$current_cron" | grep -v "$CRON_MARKER")

        if [ "$enabled" = "true" ]; then
            sched_hour=$(printf '%s' "$auto_time" | cut -d: -f1)
            sched_min=$(printf '%s' "$auto_time" | cut -d: -f2)
            sched_hour=$(strip_leading_zero "$sched_hour")
            sched_min=$(strip_leading_zero "$sched_min")

            new_cron=$(printf '%s\n%s %s * * * %s  %s' \
                "$filtered_cron" "$sched_min" "$sched_hour" "$AUTO_UPDATE_SCRIPT" "$CRON_MARKER")
            printf '%s\n' "$new_cron" | crontab -
        else
            if [ -z "$(printf '%s' "$filtered_cron" | tr -d '[:space:]')" ]; then
                echo "" | crontab -
            else
                printf '%s\n' "$filtered_cron" | crontab -
            fi
        fi

        cgi_success
        exit 0
    fi

    # --- Download update (stage without installing) ---
    if [ "$ACTION" = "download" ]; then
        check_lock
        ensure_updater_executable || exit 0

        version=$(printf '%s' "$POST_DATA" | jq -r '.version // empty')
        if [ -z "$version" ]; then
            cgi_error "missing_version" "version is required"; exit 0
        fi

        download_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/qmanager.tar.gz"
        checksum_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/sha256sum.txt"

        jq -n '{"success":true,"status":"starting"}'
        ( "$UPDATER" download "$download_url" "$checksum_url" "$version" </dev/null >>/tmp/qmanager_update.log 2>&1 & )
        exit 0
    fi

    # --- Install staged tarball ---
    if [ "$ACTION" = "install_staged" ]; then
        check_lock
        ensure_updater_executable || exit 0

        if [ ! -f "$STAGED_TARBALL" ]; then
            cgi_error "no_staged" "No staged download found. Download first."
            exit 0
        fi

        jq -n '{"success":true,"status":"starting"}'
        ( "$UPDATER" install_staged </dev/null >>/tmp/qmanager_update.log 2>&1 & )
        exit 0
    fi

    # --- Install update ---
    if [ "$ACTION" = "install" ]; then
        check_lock
        ensure_updater_executable || exit 0

        download_url=$(printf '%s' "$POST_DATA" | jq -r '.download_url // empty')
        version=$(printf '%s' "$POST_DATA" | jq -r '.version // empty')
        download_size=$(printf '%s' "$POST_DATA" | jq -r '.download_size // empty')

        if [ -z "$download_url" ]; then
            cgi_error "missing_url" "download_url is required"; exit 0
        fi

        # Respond immediately, spawn background updater (double-fork)
        jq -n '{"success":true,"status":"starting"}'
        ( "$UPDATER" install "$download_url" "$version" "$download_size" </dev/null >>/tmp/qmanager_update.log 2>&1 & )
        exit 0
    fi

    # --- Rollback ---
    if [ "$ACTION" = "rollback" ]; then
        check_lock
        ensure_updater_executable || exit 0

        if [ ! -f "$UPDATES_DIR/previous_version" ]; then
            cgi_error "no_rollback" "No previous version available for rollback"
            exit 0
        fi

        rollback_version=$(cat "$UPDATES_DIR/previous_version" 2>/dev/null)
        rollback_url="https://github.com/${GITHUB_REPO}/releases/download/${rollback_version}/qmanager.tar.gz"
        jq -n --arg v "$rollback_version" '{"success":true,"status":"starting","version":$v}'
        ( "$UPDATER" rollback "$rollback_url" "$rollback_version" </dev/null >>/tmp/qmanager_update.log 2>&1 & )
        exit 0
    fi

    cgi_error "unknown_action" "Unknown action: $ACTION"
    exit 0
fi

cgi_method_not_allowed
