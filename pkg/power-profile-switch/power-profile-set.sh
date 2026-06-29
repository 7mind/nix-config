# Select a power-profiles-daemon profile based on the connected charger.
#
# Arguments:
#   $1 = profileOnAC       profile when on a qualifying charger
#   $2 = profileOnBattery  profile otherwise
#   $3 = powerprofilesctl  path to powerprofilesctl
#   $4 = minWatts          if non-empty, enable the USB-PD charger policy with
#                          this wattage floor; if empty, use the legacy
#                          "any Mains adapter online -> AC" behavior.
#
# USB-PD charger policy (when minWatts is set):
#   performance  <=>  a USB-PD source advertises unconstrained_power=1 (a mains
#                     wall charger, NOT a battery-powered powerbank) AND its max
#                     advertised power >= minWatts.
#   power-saver  otherwise (powerbank, weak charger, or on battery).
#
# Why these signals:
#   - unconstrained_power is the USB-PD Fixed-Supply PDO bit a source sets only
#     when it is NOT power-constrained (mains). Powerbanks clear it regardless
#     of wattage, so this is the one signal that separates a 100 W powerbank
#     from a 100 W wall charger. PD Discover Identity (which would name the
#     charger) is not advertised by these chargers, so VID matching is out.
#   - The laptop's own downstream-facing ports advertise unconstrained_power=0,
#     dual_role_power=1, so they are naturally excluded.
#   - Pure sysfs, charge-limit independent: the source-capabilities persist
#     while the charger is connected even when the battery sits at its limit.
#
# PD_ROOT is overridable for testing (defaults to the real sysfs path).

set -uo pipefail

PD_ROOT="${PD_ROOT:-/sys/class/usb_power_delivery}"

log() { echo "power-profile-switch: $*"; }

r() { cat "$1" 2>/dev/null; }

# Is any Mains-type adapter online? (legacy mode)
mains_online() {
  local supply
  for supply in /sys/class/power_supply/*/; do
    [ "$(r "$supply/type")" = "Mains" ] || continue
    [ "$(r "$supply/online")" = "1" ] && return 0
  done
  return 1
}

# Max whole-watt power across the fixed_supply PDOs of one source-capabilities
# dir. voltage is "<n>mV", maximum_current is "<n>mA"; mV*mA/1e6 = W.
pd_max_fixed_watts() {
  local sc="$1" pdo v i w best=0
  for pdo in "$sc"/*:fixed_supply/; do
    [ -d "$pdo" ] || continue
    v="$(r "${pdo}voltage")";        v="${v%mV}"
    i="$(r "${pdo}maximum_current")"; i="${i%mA}"
    [[ "$v" =~ ^[0-9]+$ && "$i" =~ ^[0-9]+$ ]] || continue
    w=$(( v * i / 1000000 ))
    [ "$w" -gt "$best" ] && best="$w"
  done
  echo "$best"
}

# Highest advertised power (W) across all UNCONSTRAINED (mains) PD sources.
# Returns 0 if none present.
best_unconstrained_watts() {
  local pd sc best=0 w
  for pd in "$PD_ROOT"/*/; do
    sc="${pd}source-capabilities"
    [ -d "$sc" ] || continue
    [ "$(r "${sc}/1:fixed_supply/unconstrained_power")" = "1" ] || continue
    w="$(pd_max_fixed_watts "$sc")"
    [ "$w" -gt "$best" ] && best="$w"
  done
  echo "$best"
}

main() {
  local PROFILE_AC="${1:-performance}"
  local PROFILE_BATTERY="${2:-power-saver}"
  local PPCTL="${3:-powerprofilesctl}"
  local MIN_WATTS="${4:-}"

  local target

  if [ -z "$MIN_WATTS" ]; then
    if mains_online; then target="$PROFILE_AC"; else target="$PROFILE_BATTERY"; fi
    log "legacy: mains_online=$(mains_online && echo yes || echo no) -> $target"
  else
    local w; w="$(best_unconstrained_watts)"
    if [ "$w" -ge "$MIN_WATTS" ]; then target="$PROFILE_AC"; else target="$PROFILE_BATTERY"; fi
    log "pd-policy: best unconstrained charger=${w}W (floor ${MIN_WATTS}W) -> $target"
  fi

  "$PPCTL" set "$target"
}
