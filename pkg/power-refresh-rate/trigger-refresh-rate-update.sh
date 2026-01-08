# Signal all graphical user sessions to update refresh rate
# Arguments: $1 = loginctl path

set -euo pipefail

main() {
  local LOGINCTL="${1:-loginctl}"

  "$LOGINCTL" list-sessions --no-legend | while read -r session rest; do
    user=$("$LOGINCTL" show-session "$session" -p Name --value 2>/dev/null)
    type=$("$LOGINCTL" show-session "$session" -p Type --value 2>/dev/null)
    [ "$type" = "wayland" ] || [ "$type" = "x11" ] || continue
    uid=$(id -u "$user" 2>/dev/null) || continue
    runtime_dir="/run/user/$uid"
    trigger_file="$runtime_dir/refresh-rate-trigger"
    # Create/update trigger file with user ownership so path unit can watch it
    if [ -d "$runtime_dir" ]; then
      touch "$trigger_file" 2>/dev/null || true
      chown "$uid:$uid" "$trigger_file" 2>/dev/null || true
    fi
  done
}
