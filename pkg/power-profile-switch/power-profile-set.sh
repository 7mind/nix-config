# Select a power-profiles-daemon profile based on the connected charger.
# Charger detection lives in charger-detect.sh (prepended by default.nix).
#
# Arguments:
#   $1 = profileOnAC       profile when on a qualifying charger
#   $2 = profileOnBattery  profile otherwise
#   $3 = powerprofilesctl  path to powerprofilesctl
#   $4 = minWatts          if non-empty, enable the USB-PD unconstrained-charger
#                          + wattage-floor policy; if empty, use the legacy
#                          "any Mains adapter online -> AC" behavior.

set -uo pipefail

log() { echo "power-profile-switch: $*"; }

main() {
  local PROFILE_AC="${1:-performance}"
  local PROFILE_BATTERY="${2:-power-saver}"
  local PPCTL="${3:-powerprofilesctl}"
  local MIN_WATTS="${4:-}"

  local target

  if [ -z "$MIN_WATTS" ]; then
    if on_ac_power; then target="$PROFILE_AC"; else target="$PROFILE_BATTERY"; fi
    log "legacy: mains_online=$(charger_mains_online && echo yes || echo no) -> $target"
  else
    local w; w="$(charger_best_unconstrained_watts)"
    if [ "$w" -ge "$MIN_WATTS" ]; then target="$PROFILE_AC"; else target="$PROFILE_BATTERY"; fi
    log "pd-policy: best unconstrained charger=${w}W (floor ${MIN_WATTS}W) -> $target"
  fi

  "$PPCTL" set "$target"
}
