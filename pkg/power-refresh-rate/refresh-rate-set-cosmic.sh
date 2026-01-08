# Set refresh rate for COSMIC using wlr-randr
# Arguments: $1 = display config (DISPLAY:MODE_AC:MODE_BATTERY per line), $2 = wlr-randr path
# Note: is_on_ac function and set -euo pipefail included via is-on-ac.sh

main() {
  local DISPLAY_CONFIG="$1"
  local WLR_RANDR="${2:-wlr-randr}"

  if is_on_ac; then
    echo "On AC power"
    MODE_IDX=1
  else
    echo "On battery"
    MODE_IDX=2
  fi

  # Process each configured display
  while IFS=: read -r display mode_ac mode_battery; do
    [ -z "$display" ] && continue
    if [ "$MODE_IDX" = "1" ]; then
      target_mode="$mode_ac"
    else
      target_mode="$mode_battery"
    fi
    echo "Setting $display -> $target_mode"
    "$WLR_RANDR" --output "$display" --mode "$target_mode" 2>&1 || true
  done <<< "$DISPLAY_CONFIG"
}
