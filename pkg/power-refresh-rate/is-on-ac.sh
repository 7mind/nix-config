# Check if system is on AC power
# Returns 0 if on AC, 1 if on battery

is_on_ac() {
  for supply in /sys/class/power_supply/*/; do
    if [ -f "$supply/type" ] && [ "$(cat "$supply/type")" = "Mains" ]; then
      if [ -f "$supply/online" ] && [ "$(cat "$supply/online")" = "1" ]; then
        return 0
      fi
    fi
  done
  return 1
}
