# Set refresh rate for GNOME using gdctl
# Arguments: $1 = display config (DISPLAY:MODE_AC:MODE_BATTERY:IS_PRIMARY per line), $2 = gdctl path

set -euo pipefail

# is_on_ac function will be included by nix

main() {
  local DISPLAY_CONFIG="$1"
  local GDCTL="${2:-gdctl}"

  if is_on_ac; then
    echo "On AC power"
    MODE_IDX=1
  else
    echo "On battery"
    MODE_IDX=2
  fi

  # Build gdctl command with all displays
  local args=""
  while IFS=: read -r display mode_ac mode_battery is_primary; do
    [ -z "$display" ] && continue
    if [ "$MODE_IDX" = "1" ]; then
      target_mode="$mode_ac"
    else
      target_mode="$mode_battery"
    fi
    local primary_flag=""
    [ "$is_primary" = "1" ] && primary_flag="--primary"
    args="$args -L $primary_flag -M $display --mode $target_mode"
    echo "Setting $display -> $target_mode"
  done <<< "$DISPLAY_CONFIG"

  [ -n "$args" ] && $GDCTL set $args 2>&1 || true
}
