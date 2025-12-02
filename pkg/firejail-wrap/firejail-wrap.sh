#!/usr/bin/env bash
set -euo pipefail

RW_PATHS=()
RO_PATHS=()
BINDS=()

show_help() {
  cat <<EOF
Usage: firejail-wrap [OPTIONS] -- COMMAND [ARGS...]

Wrapper around firejail with simplified path whitelisting.

Options:
  --rw PATH        Add read-write path (only if exists)
  --ro PATH        Add read-only path (only if exists)
  --bind SRC,DST   Bind mount SRC to DST inside jail
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

FIREJAIL_ARGS=()

for path in "${RW_PATHS[@]}"; do
  if [[ -e "$path" ]]; then
    FIREJAIL_ARGS+=(--whitelist="$path")
  fi
done

for path in "${RO_PATHS[@]}"; do
  if [[ -e "$path" ]]; then
    FIREJAIL_ARGS+=(--whitelist="$path")
    FIREJAIL_ARGS+=(--read-only="$path")
  fi
done

for bind in "${BINDS[@]}"; do
  FIREJAIL_ARGS+=(--bind="$bind")
done

set -x
exec firejail --noprofile "${FIREJAIL_ARGS[@]}" "$@"
