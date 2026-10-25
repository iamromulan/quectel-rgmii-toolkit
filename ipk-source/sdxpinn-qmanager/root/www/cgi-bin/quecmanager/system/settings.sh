#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# settings.sh — CGI Endpoint: System Settings (GET + POST)
# =============================================================================
# GET:  Returns current system settings (units, timezone, WAN guard,
#        scheduled reboot, the device clock).
# POST: Saves settings or scheduled reboot config.
#
# Config: UCI quecmanager.settings.* + system.@system[0].timezone/zonename
# Cron:   qmanager_scheduled_reboot marker
#
# Endpoint: GET/POST /cgi-bin/quecmanager/system/settings.sh
# Install location: /www/cgi-bin/quecmanager/system/settings.sh
# =============================================================================

qlog_init "cgi_system_settings"
cgi_headers
cgi_handle_options

# --- Helpers -----------------------------------------------------------------

# Ensure UCI section exists with defaults
ensure_settings_config() {
    uci -q get quecmanager.settings >/dev/null 2>&1 && return
    uci set quecmanager.settings=settings
    uci set quecmanager.settings.temp_unit=celsius
    uci set quecmanager.settings.distance_unit=km
    uci set quecmanager.settings.sched_reboot_enabled=0
    uci set quecmanager.settings.sched_reboot_time=04:00
    uci set quecmanager.settings.sched_reboot_days=0,1,2,3,4,5,6
    uci commit quecmanager
}

# Read a UCI value with fallback
uci_get() {
    local val
    val=$(uci -q get "quecmanager.settings.$1" 2>/dev/null)
    if [ -z "$val" ]; then echo "$2"; else echo "$val"; fi
}

# Strip leading zero from a time component (handle "00" -> "0", not empty)
strip_leading_zero() {
    local v
    v=$(printf '%s' "$1" | sed 's/^0//')
    [ -z "$v" ] && v="0"
    printf '%s' "$v"
}

# =============================================================================
# GET — Fetch all system settings
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Fetching system settings"
    ensure_settings_config

    # --- Unit preferences ---
    temp_unit=$(uci_get temp_unit "celsius")
    distance_unit=$(uci_get distance_unit "km")

    # --- Hostname (display name) ---
    hostname=$(uci -q get system.@system[0].hostname 2>/dev/null)
    [ -z "$hostname" ] && hostname="OpenWrt"

    # --- Timezone ---
    timezone=$(uci -q get system.@system[0].timezone 2>/dev/null)
    [ -z "$timezone" ] && timezone="UTC0"
    zonename=$(uci -q get system.@system[0].zonename 2>/dev/null)
    [ -z "$zonename" ] && zonename="UTC"

    # --- Scheduled reboot ---
    sched_enabled=$(uci_get sched_reboot_enabled "0")
    sched_time=$(uci_get sched_reboot_time "04:00")
    sched_days_raw=$(uci_get sched_reboot_days "0,1,2,3,4,5,6")
    sched_days_json=$(printf '%s' "$sched_days_raw" | jq -Rc 'split(",") | map(tonumber)' 2>/dev/null)
    [ -z "$sched_days_json" ] && sched_days_json="[0,1,2,3,4,5,6]"

    # --- Device clock ---
    # One `date` call so the epoch and the wall time come from the same second.
    # The wall time is the modem's own (its TZ), shown as-is: on a box whose
    # clock has not been set yet it reads 1970, and the UI says so.
    clock_now=$(date '+%s %Y-%m-%dT%H:%M:%S' 2>/dev/null)
    clock_epoch=${clock_now%% *}
    clock_local=${clock_now#* }
    case "$clock_epoch" in
        ''|*[!0-9]*) clock_epoch=0; clock_local="" ;;
    esac

    jq -n \
        --arg hostname "$hostname" \
        --arg temp_unit "$temp_unit" \
        --arg distance_unit "$distance_unit" \
        --arg timezone "$timezone" \
        --arg zonename "$zonename" \
        --argjson sched_enabled "$sched_enabled" \
        --arg sched_time "$sched_time" \
        --argjson sched_days "$sched_days_json" \
        --argjson clock_epoch "$clock_epoch" \
        --arg clock_local "$clock_local" \
        '{
            success: true,
            settings: {
                hostname: $hostname,
                temp_unit: $temp_unit,
                distance_unit: $distance_unit,
                timezone: $timezone,
                zonename: $zonename
            },
            scheduled_reboot: {
                enabled: ($sched_enabled == 1),
                time: $sched_time,
                days: $sched_days
            },
            device_clock: {
                epoch: $clock_epoch,
                local: $clock_local
            }
        }'
    exit 0
fi

# =============================================================================
# POST — Save settings
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty')

    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: save_settings
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "save_settings" ]; then
        qlog_info "Saving system settings"
        ensure_settings_config

        val=""

        # The retired force_tailscale_fixes key (now automatic, toggled on the
        # Tailscale page) is ignored if an old client still posts it.

        # --- Hostname (display name) ---
        # system_dirty flags when any system.@system[0].* key changes so we can
        # republish /tmp/TZ, /tmp/localtime, and kernel hostname via
        # /etc/init.d/system reload after commit.
        system_dirty=0
        tz_dirty=0

        val=$(printf '%s' "$POST_DATA" | jq -r '.hostname // empty')
        if [ -n "$val" ]; then
            cur=$(uci -q get system.@system[0].hostname 2>/dev/null)
            if [ "$val" != "$cur" ]; then
                uci set system.@system[0].hostname="$val"
                system_dirty=1
            fi
        fi

        # --- Temperature unit ---
        val=$(printf '%s' "$POST_DATA" | jq -r '.temp_unit // empty')
        if [ -n "$val" ]; then
            case "$val" in
                celsius|fahrenheit) uci set quecmanager.settings.temp_unit="$val" ;;
                *)
                    cgi_error "invalid_temp_unit" "temp_unit must be 'celsius' or 'fahrenheit'"
                    exit 0
                    ;;
            esac
        fi

        # --- Distance unit ---
        val=$(printf '%s' "$POST_DATA" | jq -r '.distance_unit // empty')
        if [ -n "$val" ]; then
            case "$val" in
                km|miles) uci set quecmanager.settings.distance_unit="$val" ;;
                *)
                    cgi_error "invalid_distance_unit" "distance_unit must be 'km' or 'miles'"
                    exit 0
                    ;;
            esac
        fi

        # --- Timezone ---
        # tz_dirty additionally triggers crond restart — busybox crond caches
        # TZ at startup, so the Scheduled Reboot cron fires at stale wall
        # time until restart.
        val=$(printf '%s' "$POST_DATA" | jq -r '.timezone // empty')
        if [ -n "$val" ]; then
            cur=$(uci -q get system.@system[0].timezone 2>/dev/null)
            if [ "$val" != "$cur" ]; then
                uci set system.@system[0].timezone="$val"
                system_dirty=1
                tz_dirty=1
            fi
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.zonename // empty')
        if [ -n "$val" ]; then
            cur=$(uci -q get system.@system[0].zonename 2>/dev/null)
            if [ "$val" != "$cur" ]; then
                uci set system.@system[0].zonename="$val"
                system_dirty=1
                tz_dirty=1
            fi
        fi

        # Commit changes
        uci commit quecmanager
        uci commit system

        # Republish system config to /tmp/TZ, /tmp/localtime, kernel hostname,
        # syslogd. Backgrounded so the HTTP response returns promptly; matches
        # the pattern used by ip_passthrough.sh reboot-on-apply.
        if [ "$system_dirty" = "1" ]; then
            qlog_info "system dirty: scheduling /etc/init.d/system reload"
            ( /etc/init.d/system reload </dev/null >/dev/null 2>&1 & )

            # crond is NOT restarted by /etc/init.d/system reload. On TZ
            # change, restart it so qmanager_scheduled_reboot cron entries
            # fire at the new wall time.
            if [ "$tz_dirty" = "1" ]; then
                qlog_info "TZ changed: scheduling /etc/init.d/cron restart"
                ( /etc/init.d/cron restart </dev/null >/dev/null 2>&1 & )
            fi
        fi

        qlog_info "System settings saved"
        echo '{"success":true}'
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: save_scheduled_reboot
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "save_scheduled_reboot" ]; then
        qlog_info "Saving scheduled reboot settings"
        ensure_settings_config

        # Parse fields
        ENABLED=$(printf '%s' "$POST_DATA" | jq -r 'if has("enabled") then (.enabled | tostring) else "" end')
        SCHED_TIME=$(printf '%s' "$POST_DATA" | jq -r '.time // empty')
        DAYS_RAW=$(printf '%s' "$POST_DATA" | jq -r '.days // [] | map(tostring) | join(",")' 2>/dev/null)

        if [ -z "$ENABLED" ]; then
            cgi_error "missing_enabled" "enabled field is required"
            exit 0
        fi

        # Validate when enabling
        if [ "$ENABLED" = "true" ]; then
            # Validate time format HH:MM
            case "$SCHED_TIME" in
                [0-2][0-9]:[0-5][0-9]) ;;
                *)
                    cgi_error "invalid_time" "time must be HH:MM format"
                    exit 0
                    ;;
            esac

            # Validate days
            if [ -z "$DAYS_RAW" ]; then
                cgi_error "no_days" "At least one day must be selected"
                exit 0
            fi

            invalid_day=""
            for d in $(printf '%s' "$DAYS_RAW" | tr ',' ' '); do
                case "$d" in
                    0|1|2|3|4|5|6) ;;
                    *) invalid_day="$d" ;;
                esac
            done
            if [ -n "$invalid_day" ]; then
                cgi_error "invalid_day" "Days must be 0-6 (0=Sun, 6=Sat)"
                exit 0
            fi
        fi

        # Defaults for disabled state
        [ -z "$SCHED_TIME" ] && SCHED_TIME="04:00"
        [ -z "$DAYS_RAW" ] && DAYS_RAW="0,1,2,3,4,5,6"

        # Write to UCI
        case "$ENABLED" in
            true)  uci set quecmanager.settings.sched_reboot_enabled=1 ;;
            false) uci set quecmanager.settings.sched_reboot_enabled=0 ;;
        esac
        uci set quecmanager.settings.sched_reboot_time="$SCHED_TIME"
        uci set quecmanager.settings.sched_reboot_days="$DAYS_RAW"
        uci commit quecmanager

        # --- Manage crontab ---
        CRON_MARKER="qmanager_scheduled_reboot"
        SCHEDULE_SCRIPT="/usr/bin/qmanager_scheduled_reboot"

        # The header comment carries no marker, so strip it too; otherwise every
        # save leaves the old header behind and the blocks stack up.
        current_cron=$(crontab -l 2>/dev/null || true)
        cleaned_cron=$(printf '%s\n' "$current_cron" | grep -v "$CRON_MARKER" \
            | grep -v "^# QManager Scheduled Reboot")

        if [ "$ENABLED" = "true" ]; then
            sched_hour=$(printf '%s' "$SCHED_TIME" | cut -d: -f1)
            sched_min=$(printf '%s' "$SCHED_TIME" | cut -d: -f2)
            sched_hour=$(strip_leading_zero "$sched_hour")
            sched_min=$(strip_leading_zero "$sched_min")

            new_cron="${cleaned_cron}
# QManager Scheduled Reboot — DO NOT EDIT MANUALLY
${sched_min} ${sched_hour} * * ${DAYS_RAW} ${SCHEDULE_SCRIPT}  # ${CRON_MARKER}"

            printf '%s\n' "$new_cron" | crontab -
            qlog_info "Scheduled reboot cron installed: ${SCHED_TIME} days=${DAYS_RAW}"
        else
            if [ -n "$cleaned_cron" ]; then
                printf '%s\n' "$cleaned_cron" | crontab -
            else
                echo "" | crontab -
            fi
            qlog_info "Scheduled reboot cron entries removed"
        fi

        # Build response
        DAYS_RESP=$(printf '%s' "$DAYS_RAW" | jq -Rc 'split(",") | map(tonumber)' 2>/dev/null)
        [ -z "$DAYS_RESP" ] && DAYS_RESP="[0,1,2,3,4,5,6]"

        jq -n \
            --argjson enabled "$([ "$ENABLED" = "true" ] && echo true || echo false)" \
            --arg time "$SCHED_TIME" \
            --argjson days "$DAYS_RESP" \
            '{success: true, scheduled_reboot: {enabled: $enabled, time: $time, days: $days}}'
        exit 0
    fi

    # Unknown action
    cgi_error "unknown_action" "Unknown action: $ACTION"
    exit 0
fi

# Method not allowed
cgi_error "method_not_allowed" "Only GET and POST are supported"
