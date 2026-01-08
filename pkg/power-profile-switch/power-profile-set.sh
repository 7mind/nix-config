#!/usr/bin/env bash
# Set power profile based on AC/battery status
# Arguments: $1 = profileOnAC, $2 = profileOnBattery, $3 = powerprofilesctl path

set -euo pipefail

PROFILE_AC="${1:-performance}"
PROFILE_BATTERY="${2:-power-saver}"
POWERPROFILESCTL="${3:-powerprofilesctl}"

# Check if any AC adapter is online
for supply in /sys/class/power_supply/*/; do
  if [ -f "$supply/type" ] && [ "$(cat "$supply/type")" = "Mains" ]; then
    if [ -f "$supply/online" ] && [ "$(cat "$supply/online")" = "1" ]; then
      "$POWERPROFILESCTL" set "$PROFILE_AC"
      exit 0
    fi
  fi
done

"$POWERPROFILESCTL" set "$PROFILE_BATTERY"
