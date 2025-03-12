#!/bin/sh

# Set content type for JSON response
echo "Content-type: application/json"
echo ""

# Get system uptime in seconds from /proc/uptime
read uptime idle < /proc/uptime
uptime=${uptime%.*}  # Remove decimal part

# Calculate days, hours, minutes, seconds
days=$((uptime/86400))
hours=$(((uptime%86400)/3600))
minutes=$(((uptime%3600)/60))
seconds=$((uptime%60))

# Format uptime string
uptime_str=""
[ $days -gt 0 ] && uptime_str="${days}d "
[ $hours -gt 0 ] && uptime_str="${uptime_str}${hours}h "
[ $minutes -gt 0 ] && uptime_str="${uptime_str}${minutes}m "
uptime_str="${uptime_str}${seconds}s"

# Create and output JSON response
cat << EOF
{
    "status": "success",
    "timestamp": "$(date -Iseconds)",
    "uptime": {
        "total_seconds": $uptime,
        "days": $days,
        "hours": $hours,
        "minutes": $minutes,
        "seconds": $seconds,
        "formatted": "${uptime_str}"
    }
}
EOF