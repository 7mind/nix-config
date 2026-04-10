#!/usr/bin/env bash
# yolo - unified LLM tool launcher with llm-sandbox
#
# Required env vars (set by Nix wrapper):
#   YOLO_LLM_SANDBOX            - path to llm-sandbox binary
#   YOLO_NIX_LD                 - path to nix-ld binary (bound as /lib64/ld-linux-x86-64.so.2)
#   YOLO_JQ                     - path to jq binary
#   YOLO_COPILOT_DEFAULT_CONFIG - path to copilot default config JSON
#   YOLO_COPILOT_BIN            - path to copilot binary
#
# Optional env vars:
#   YOLO_PODMAN_SOCKET_PATH - rootless podman socket path (enables container forwarding)
#   YOLO_PODMAN_SOCKET_URI  - rootless podman socket URI

: "${YOLO_LLM_SANDBOX:?must be set}"
: "${YOLO_NIX_LD:?must be set}"
: "${YOLO_JQ:?must be set}"
: "${YOLO_COPILOT_DEFAULT_CONFIG:?must be set}"
: "${YOLO_COPILOT_BIN:?must be set}"

WORK_MODE=0
ENV_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work|-w) WORK_MODE=1; shift ;;
    --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
    -*) echo "Unknown flag: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "Usage: yolo [--work] [--env KEY=VAL]... <claude|codex|copilot|gemini|vibe|opencode> [args...]" >&2
  exit 1
fi

SUBCMD="$1"; shift
CMD_ARGS=("$@")

# Container socket forwarding (triggered by YOLO_PODMAN_SOCKET_PATH)
SOCKET_ARGS=()
if [[ -n "${YOLO_PODMAN_SOCKET_PATH:-}" && -n "${YOLO_PODMAN_SOCKET_URI:-}" ]]; then
  if [[ -S "$YOLO_PODMAN_SOCKET_PATH" ]]; then
    SOCKET_ARGS+=(--rw "$YOLO_PODMAN_SOCKET_PATH")
    SOCKET_ARGS+=(--env "DOCKER_HOST=$YOLO_PODMAN_SOCKET_URI")
    SOCKET_ARGS+=(--env "CONTAINER_HOST=$YOLO_PODMAN_SOCKET_URI")
  else
    echo "warning: podsvc-llm Podman socket not available, skipping bind: $YOLO_PODMAN_SOCKET_PATH" >&2
  fi
fi

BASE_ARGS=(
  --rw "${PWD}"
  --rw "${HOME}/.cache"
  --rw "${HOME}/.ivy2"
  "${SOCKET_ARGS[@]}"
  --ro "${HOME}/.config/git"
  --ro "${HOME}/.config/direnv"
  --ro "${HOME}/.local/share/direnv"
  --ro "${HOME}/.direnvrc"
  --ro-bind "${YOLO_NIX_LD},/lib64/ld-linux-x86-64.so.2"
  --env SMIND_SANDBOXED=1
  "${ENV_ARGS[@]}"
)

EXTRA_ARGS=()
EXEC_CMD=()

ensure_copilot_config() {
  local config_dir="$1"
  local trusted_dir="$2"
  local config_file="$config_dir/config.json"
  local tmp_config

  mkdir -p "$config_dir"
  tmp_config="$(mktemp)"

  if [[ -f "$config_file" ]]; then
    "$YOLO_JQ" \
      --slurpfile defaults "$YOLO_COPILOT_DEFAULT_CONFIG" \
      --arg trusted_dir "$trusted_dir" \
      '
        ($defaults[0] + .)
        | .trusted_folders = (((.trusted_folders // []) + [$trusted_dir]) | unique)
      ' \
      "$config_file" > "$tmp_config"
  else
    "$YOLO_JQ" \
      -n \
      --slurpfile defaults "$YOLO_COPILOT_DEFAULT_CONFIG" \
      --arg trusted_dir "$trusted_dir" \
      '
        $defaults[0]
        | .trusted_folders = (((.trusted_folders // []) + [$trusted_dir]) | unique)
      ' > "$tmp_config"
  fi

  mv "$tmp_config" "$config_file"
}

case "$SUBCMD" in
  claude)
    if [[ $WORK_MODE -eq 1 ]]; then
      mkdir -p "${HOME}/.claude-work" "${HOME}/.claude-work-home" "${HOME}/.config/claude-work"
      touch "${HOME}/.claude-work-home/.claude.json"
      EXTRA_ARGS+=(
        --bind "${HOME}/.claude-work,${HOME}/.claude"
        --bind "${HOME}/.claude-work-home/.claude.json,${HOME}/.claude.json"
        --bind "${HOME}/.config/claude-work,${HOME}/.config/claude"
      )
    else
      EXTRA_ARGS+=(
        --rw "${HOME}/.claude"
        --rw "${HOME}/.claude.json"
        --rw "${HOME}/.config/claude"
      )
    fi
    EXTRA_ARGS+=(
      --rw "${HOME}/.codex"
      --rw "${HOME}/.config/codex"
    )
    EXEC_CMD=(claude --permission-mode bypassPermissions "${CMD_ARGS[@]}")
    ;;

  codex)
    if [[ $WORK_MODE -eq 1 ]]; then
      echo "Error: --work is not supported for codex" >&2; exit 1
    fi
    EXTRA_ARGS+=(
      --rw "${HOME}/.codex"
      --rw "${HOME}/.config/codex"
    )
    EXEC_CMD=(codex --dangerously-bypass-approvals-and-sandbox --search "${CMD_ARGS[@]}")
    ;;

  copilot)
    if [[ $WORK_MODE -eq 1 ]]; then
      COPILOT_CONFIG_DIR="${HOME}/.copilot-work"
      EXTRA_ARGS+=(--rw "${HOME}/.copilot-work")
    else
      COPILOT_CONFIG_DIR="${HOME}/.copilot"
      EXTRA_ARGS+=(--rw "${HOME}/.copilot")
    fi
    EXTRA_ARGS+=(--ro "${HOME}/.config/gh")

    ensure_copilot_config "$COPILOT_CONFIG_DIR" "${PWD}"

    copilot_args=(--config-dir "$COPILOT_CONFIG_DIR")
    case "${CMD_ARGS[0]-}" in
      help|init|login|plugin|update|version) ;;
      *)
        copilot_args+=(
          --model "$YOLO_COPILOT_MODEL"
          --reasoning-effort "$YOLO_COPILOT_REASONING_EFFORT"
          --autopilot
          --yolo
        )
        ;;
    esac

    EXEC_CMD=("$YOLO_COPILOT_BIN" "${copilot_args[@]}" "${CMD_ARGS[@]}")
    ;;

  gemini)
    if [[ $WORK_MODE -eq 1 ]]; then
      EXTRA_ARGS+=(--bind "${HOME}/.gemini-work,${HOME}/.gemini")
    else
      EXTRA_ARGS+=(--rw "${HOME}/.gemini")
    fi
    EXEC_CMD=(gemini --yolo "${CMD_ARGS[@]}")
    ;;

  vibe)
    if [[ $WORK_MODE -eq 1 ]]; then
      echo "Error: --work is not supported for vibe" >&2; exit 1
    fi
    mkdir -p "${HOME}/.vibe" "${HOME}/.local/share/vibe"
    EXTRA_ARGS+=(
      --rw "${HOME}/.vibe"
      --rw "${HOME}/.local/share/vibe"
    )
    EXEC_CMD=(vibe --agent auto-approve "${CMD_ARGS[@]}")
    ;;

  opencode)
    if [[ $WORK_MODE -eq 1 ]]; then
      echo "Error: --work is not supported for opencode" >&2; exit 1
    fi
    EXTRA_ARGS+=(
      --rw "${HOME}/.config/opencode"
      --rw "${HOME}/.local/share/opencode"
    )
    EXEC_CMD=(opencode "${CMD_ARGS[@]}")
    ;;

  *)
    echo "Unknown tool: $SUBCMD" >&2
    echo "Supported: claude, codex, copilot, gemini, vibe, opencode" >&2
    exit 1
    ;;
esac

exec "$YOLO_LLM_SANDBOX" \
  "${BASE_ARGS[@]}" \
  "${EXTRA_ARGS[@]}" \
  -- "${EXEC_CMD[@]}"
