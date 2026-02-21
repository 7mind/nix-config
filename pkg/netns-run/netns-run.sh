#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: netns-run [OPTIONS] [--] COMMAND [ARGS...]

Run a command in a network namespace and/or systemd user slice.

Options:
  -n, --netns NAME     Network namespace name
  -s, --slice NAME     Run inside a systemd user scope under this slice
  -h, --help           Show this help
EOF
  exit "${1:-0}"
}

netns=""
slice=""
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

if [[ -n "$netns" ]]; then
  run_cmd=(/run/wrappers/bin/firejail --noprofile "--netns=$netns" -- "${cmd[@]}")
else
  run_cmd=("${cmd[@]}")
fi

if [[ -n "$slice" ]]; then
  exec systemd-run --user --scope "--slice=$slice" "${run_cmd[@]}"
else
  exec "${run_cmd[@]}"
fi
