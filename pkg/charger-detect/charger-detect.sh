# Shared charger detection for the power-profiles and refresh-rate switchers.
# Source this file, then call `on_ac_power [minWatts]`:
#
#   - empty/no minWatts: returns 0 ("on AC") if any Mains adapter is online.
#   - minWatts set: returns 0 only if a USB-PD source advertises
#     unconstrained_power=1 (a mains wall charger, not a battery-powered
#     powerbank) AND its max advertised power is >= minWatts; else returns 1.
#
# All helpers are safe under `set -euo pipefail`. PD_ROOT is overridable for
# testing (defaults to the real sysfs path).

PD_ROOT="${PD_ROOT:-/sys/class/usb_power_delivery}"

_cd_read() { cat "$1" 2>/dev/null; }

# 0 if any Mains-type adapter reports online.
charger_mains_online() {
  local supply
  for supply in /sys/class/power_supply/*/; do
    [ "$(_cd_read "$supply/type")" = "Mains" ] || continue
    [ "$(_cd_read "$supply/online")" = "1" ] && return 0
  done
  return 1
}

# Max whole-watt power across the fixed_supply PDOs of one source-capabilities
# dir. voltage is "<n>mV", maximum_current is "<n>mA"; mV*mA/1e6 = W.
charger_pd_max_fixed_watts() {
  local sc="$1" pdo v i w best=0
  for pdo in "$sc"/*:fixed_supply/; do
    [ -d "$pdo" ] || continue
    v="$(_cd_read "${pdo}voltage")";        v="${v%mV}"
    i="$(_cd_read "${pdo}maximum_current")"; i="${i%mA}"
    [[ "$v" =~ ^[0-9]+$ && "$i" =~ ^[0-9]+$ ]] || continue
    w=$(( v * i / 1000000 ))
    [ "$w" -gt "$best" ] && best="$w"
  done
  echo "$best"
}

# Highest advertised power (W) across all UNCONSTRAINED (mains) PD sources; 0
# if none present (e.g. powerbank-only or on battery).
charger_best_unconstrained_watts() {
  local pd sc best=0 w
  for pd in "$PD_ROOT"/*/; do
    sc="${pd}source-capabilities"
    [ -d "$sc" ] || continue
    [ "$(_cd_read "${sc}/1:fixed_supply/unconstrained_power")" = "1" ] || continue
    w="$(charger_pd_max_fixed_watts "$sc")"
    [ "$w" -gt "$best" ] && best="$w"
  done
  echo "$best"
}

# on_ac_power [minWatts] -> exit 0 if on qualifying AC, else 1.
on_ac_power() {
  local min="${1:-}"
  if [ -z "$min" ]; then
    if charger_mains_online; then return 0; else return 1; fi
  fi
  local w; w="$(charger_best_unconstrained_watts)"
  if [ "$w" -ge "$min" ]; then return 0; else return 1; fi
}
