#!/usr/bin/env bash
set -euo pipefail

RW_PATHS=()
RO_PATHS=()
BINDS=()
ENVS=()

show_help() {
  cat <<EOF
Usage: firejail-wrap [OPTIONS] -- COMMAND [ARGS...]

Wrapper around bubblewrap with simplified path whitelisting.

Options:
  --rw PATH        Add read-write path (only if exists)
  --ro PATH        Add read-only path (only if exists)
  --bind SRC,DST   Bind mount SRC to DST inside sandbox
  --env VAR=VALUE  Set environment variable inside sandbox
  --help           Show this help

Example:
  firejail-wrap --rw "\$PWD" --env FOO=bar -- myapp --flag
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
    --env)
      ENVS+=("$2")
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

# Nix store must be bound first (other paths are symlinks into it)
NIX_PATHS=(
  /nix/store
  /nix/var
)

for path in "${NIX_PATHS[@]}"; do
  if [[ -e "$path" ]]; then
    BWRAP_ARGS+=(--ro-bind "$path" "$path")
  fi
done

# System paths needed for executables
# Note: /etc/profiles and ~/.nix-profile are symlinks into /nix/store,
# they work automatically since both /etc and /nix/store are bound
SYSTEM_RO_PATHS=(
  /etc
  /bin
  /usr
  /run/current-system
  /run/wrappers
  /run/systemd/resolve
  /run/nscd
)

for path in "${SYSTEM_RO_PATHS[@]}"; do
  if [[ -e "$path" ]]; then
    BWRAP_ARGS+=(--ro-bind "$path" "$path")
  fi
done

# User-provided RO paths (filter out /nix/* as already bound)
for path in "${RO_PATHS[@]}"; do
  if [[ -e "$path" ]] && [[ "$path" != /nix/* ]]; then
    BWRAP_ARGS+=(--ro-bind "$path" "$path")
  fi
done

# User-provided RW paths
for path in "${RW_PATHS[@]}"; do
  if [[ -e "$path" ]]; then
    BWRAP_ARGS+=(--bind "$path" "$path")
  fi
done

for bind in "${BINDS[@]}"; do
  IFS=',' read -r src dst <<< "$bind"
  if [[ -e "$src" ]]; then
    BWRAP_ARGS+=(--bind "$src" "$dst")
  fi
done

# Environment variables
for env in "${ENVS[@]}"; do
  IFS='=' read -r name value <<< "$env"
  BWRAP_ARGS+=(--setenv "$name" "$value")
done

set -x
exec bwrap "${BWRAP_ARGS[@]}" "$@"
