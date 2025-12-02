#!/usr/bin/env bash
set -euo pipefail

RW_PATHS=()
RO_PATHS=()
BINDS=()

show_help() {
  cat <<EOF
Usage: firejail-wrap [OPTIONS] -- COMMAND [ARGS...]

Wrapper around bubblewrap with simplified path whitelisting.

Options:
  --rw PATH        Add read-write path (only if exists)
  --ro PATH        Add read-only path (only if exists)
  --bind SRC,DST   Bind mount SRC to DST inside sandbox
  --help           Show this help

Example:
  firejail-wrap --rw "\$PWD" --rw ~/.config/app --ro /nix/store -- myapp --flag
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rw)
      RW_PATHS+=("$2")
      shift 2
      ;;
    --ro)
      RO_PATHS+=("$2")
      shift 2
      ;;
    --bind)
      BINDS+=("$2")
      shift 2
      ;;
    --help)
      show_help
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "Error: No command specified" >&2
  exit 1
fi

BWRAP_ARGS=(
  --unshare-all
  --share-net
  --die-with-parent
  --dev /dev
  --proc /proc
  --tmpfs /tmp
)

# System paths needed for executables
SYSTEM_RO_PATHS=(
  /etc
  /bin
  /usr
  /run/current-system
  "$HOME/.nix-profile"
  "/etc/profiles/per-user/$USER"
  /run/wrappers
)

for path in "${SYSTEM_RO_PATHS[@]}"; do
  if [[ -e "$path" ]]; then
    BWRAP_ARGS+=(--ro-bind "$path" "$path")
  fi
done

for path in "${RW_PATHS[@]}"; do
  if [[ -e "$path" ]]; then
    BWRAP_ARGS+=(--bind "$path" "$path")
  fi
done

for path in "${RO_PATHS[@]}"; do
  if [[ -e "$path" ]]; then
    BWRAP_ARGS+=(--ro-bind "$path" "$path")
  fi
done

for bind in "${BINDS[@]}"; do
  IFS=',' read -r src dst <<< "$bind"
  if [[ -e "$src" ]]; then
    BWRAP_ARGS+=(--bind "$src" "$dst")
  fi
done

set -x
exec bwrap "${BWRAP_ARGS[@]}" "$@"
