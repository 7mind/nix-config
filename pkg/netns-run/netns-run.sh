#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: netns-run [OPTIONS] [--] COMMAND [ARGS...]

Run a command in a network namespace and/or systemd user slice.

Options:
  -n, --netns NAME     Network namespace name
  -s, --slice NAME     Run inside a systemd user scope under this slice
      --jailless       Enter the netns via sudo + ip netns exec (netns-exec)
                       instead of firejail. Leaves /proc unmasked, so nested
                       unprivileged sandboxes (bwrap etc.) work. Sealed with
                       no_new_privs by default.
      --no-seal        Only valid with --jailless: skip the no_new_privs seal
                       so the command can still use sudo/suid (e.g. interactive
                       shells). Error if used without --jailless.
  -h, --help           Show this help
EOF
  exit "${1:-0}"
}

netns=""
slice=""
jailless=""
noseal=""
cmd=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--netns)
      [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; usage 1; }
      netns="$2"
      shift 2
      ;;
    -s|--slice)
      [[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; usage 1; }
      slice="$2"
      shift 2
      ;;
    --jailless)
      jailless=1
      shift
      ;;
    --no-seal)
      noseal=1
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    --)
      shift
      cmd+=("$@")
      break
      ;;
    *)
      cmd+=("$1")
      shift
      ;;
  esac
done

[[ -n "$netns" || -n "$slice" ]] || { echo "error: at least one of --netns or --slice is required" >&2; usage 1; }
[[ ${#cmd[@]} -gt 0 ]] || { echo "error: no command specified" >&2; usage 1; }
[[ -z "$noseal" || -n "$jailless" ]] || { echo "error: --no-seal only applies to --jailless mode" >&2; usage 1; }

if [[ -n "$netns" ]]; then
  if [[ -n "$jailless" ]]; then
    # netns-exec (sudo helper) instead of firejail: leaves /proc unmasked so
    # nested bwrap works, unlike firejail's /proc hardening. -E keeps the
    # session env; PATH is re-set because su-family tools drop it.
    netns_exec=(/run/wrappers/bin/sudo -n -E "@out@/bin/netns-exec")
    [[ -n "$noseal" ]] && netns_exec+=(--no-seal)
    run_cmd=("${netns_exec[@]}" "$netns"
      /run/current-system/sw/bin/env "PATH=$PATH" "${cmd[@]}")
  else
    # Default (jailed): firejail drops caps and hardens /proc — which also
    # blocks nesting bwrap inside it (use --jailless for that).
    run_cmd=(/run/wrappers/bin/firejail --noprofile "--netns=$netns" -- "${cmd[@]}")
  fi
else
  run_cmd=("${cmd[@]}")
fi

if [[ -n "$slice" ]]; then
  exec systemd-run --user --scope "--slice=$slice" "${run_cmd[@]}"
else
  exec "${run_cmd[@]}"
fi
