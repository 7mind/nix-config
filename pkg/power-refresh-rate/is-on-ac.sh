# Determine AC state for refresh-rate switching.
#
# Honors the USB-PD charger policy via REFRESH_AC_MIN_WATTS (embedded by
# default.nix): empty => any Mains adapter online; a wattage => require an
# unconstrained mains charger of at least that many watts (so low-power
# adapters / powerbanks keep the battery refresh rate). The actual detection
# (on_ac_power) comes from charger-detect.sh, prepended ahead of this file.

set -euo pipefail

is_on_ac() {
  on_ac_power "${REFRESH_AC_MIN_WATTS:-}"
}
