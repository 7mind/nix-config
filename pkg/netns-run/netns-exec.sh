#!/usr/bin/env bash
# Root helper for `netns-run --jailless`, invoked via sudo. Joins the named
# netns, then drops back to the invoking user.
# Seals with no_new_privs by default so the dropped command can't regain
# privileges (no suid/sudo hop into another netns); --no-seal opts out.
set -euo pipefail

seal=1
if [[ "${1:-}" == "--no-seal" ]]; then
  seal=0
  shift
fi

if [[ $EUID -ne 0 || -z "${SUDO_USER:-}" ]]; then
  echo "error: netns-exec must be invoked as root via sudo" >&2
  exit 1
fi
[[ $# -ge 2 ]] || { echo "usage: netns-exec [--no-seal] NETNS COMMAND [ARGS...]" >&2; exit 1; }

netns="$1"
shift

seal_cmd=()
if [[ $seal -eq 1 ]]; then
  seal_cmd=(/run/current-system/sw/bin/setpriv --no-new-privs --)
fi

exec /run/current-system/sw/bin/ip netns exec "$netns" \
  /run/current-system/sw/bin/runuser -u "$SUDO_USER" -- "${seal_cmd[@]}" "$@"
