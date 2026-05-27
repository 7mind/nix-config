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
#   YOLO_HW_NVIDIA_ENABLE    - "1" if smind.hw.nvidia.enable is set on the host (gates --gpu)
#   YOLO_HW_AMD_GPU_ENABLE   - "1" if smind.hw.amd.gpu.enable is set on the host (gates --gpu)
#   YOLO_HW_INTEL_GPU_ENABLE - "1" if smind.hw.intel.gpu.enable is set on the host (gates --gpu)
#   YOLO_LLM_SSH_KEY_PATH    - path to an agenix-managed SSH private key to ro-bind into the sandbox
#                              (set on llm-worker hosts so the llm user can use the key inside yolo)
#   YOLO_GPU_DEFAULT         - "1" to default --gpu on (CLI --no-gpu opts out)
#   YOLO_EXTRA_RO_PATHS      - newline-separated list of host paths to ro-bind (missing paths are skipped)
#   YOLO_EXTRA_RW_PATHS      - newline-separated list of host paths to rw-bind (missing paths are skipped)
#   YOLO_OLLAMA_MODELS_DIR   - host path to the ollama models directory (ro-bind); empty means no ollama on this host
#   YOLO_EXTRA_PROMPT        - extra text appended to the claude system prompt (after the YOLO header)

: "${YOLO_LLM_SANDBOX:?must be set}"
: "${YOLO_NIX_LD:?must be set}"
: "${YOLO_JQ:?must be set}"
: "${YOLO_COPILOT_DEFAULT_CONFIG:?must be set}"
: "${YOLO_COPILOT_BIN:?must be set}"

WORK_MODE=0
MOBILE_MODE=0
GPU_MODE=${YOLO_GPU_DEFAULT:-0}
ENV_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work|-w) WORK_MODE=1; shift ;;
    --mobile) MOBILE_MODE=1; shift ;;
    --gpu) GPU_MODE=1; shift ;;
    --no-gpu) GPU_MODE=0; shift ;;
    --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
    -*) echo "Unknown flag: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

if [[ $MOBILE_MODE -eq 1 ]]; then
  if [[ -n "${TMUX:-}" ]]; then
    tmux set-window-option window-size manual
    tmux resize-window -x 59 -y 33
  else
    echo "warning: --mobile requires tmux, ignoring" >&2
  fi
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: yolo [--work] [--mobile] [--gpu|--no-gpu] [--env KEY=VAL]... <claude|codex|copilot|gemini|vibe|opencode|shell|cmd> [args...]" >&2
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

# If we're inside tmux, bind its socket directory into the sandbox. Without
# this, tools like claude-code detect $TMUX and try `tmux load-buffer -` to
# copy, which fails because /tmp is tmpfs'd inside the sandbox and tmux
# can't reach its socket. The parent dir is typically /tmp/tmux-<uid>/.
TMUX_BIND_ARGS=()
if [[ -n "${TMUX:-}" ]]; then
  _tmux_sock="${TMUX%%,*}"
  if [[ -S "$_tmux_sock" ]]; then
    TMUX_BIND_ARGS+=(--rw "$(dirname "$_tmux_sock")")
  fi
fi

GPU_ARGS=()
if [[ $GPU_MODE -eq 1 ]]; then
  if [[ "${YOLO_HW_NVIDIA_ENABLE:-0}" != "1" \
     && "${YOLO_HW_AMD_GPU_ENABLE:-0}" != "1" \
     && "${YOLO_HW_INTEL_GPU_ENABLE:-0}" != "1" ]]; then
    echo "warning: --gpu requested but none of smind.hw.{nvidia,amd.gpu,intel.gpu}.enable is set on this host; ignoring" >&2
  else
    # /run/opengl-driver carries NixOS-managed GPU userspace libs (libcuda,
    # libamdhip64, intel-compute-runtime, level-zero, mesa drivers, vulkan ICDs).
    # Required for NVIDIA, AMD and Intel.
    if [[ -e /run/opengl-driver ]]; then
      GPU_ARGS+=(--ro /run/opengl-driver)
    fi
    # /sys is needed for GPU enumeration — ROCm reads /sys/class/kfd/kfd/topology,
    # NVIDIA tools probe /sys/class/drm and /sys/bus/pci, Intel Level Zero / xe
    # walks /sys/class/drm and /sys/bus/pci to discover devices and SR-IOV VFs.
    GPU_ARGS+=(--ro /sys)
    # /dev/dri is shared by AMD, NVIDIA (PRIME offload, Vulkan), and Intel
    # (render nodes are the primary compute path for Level Zero / OpenCL on xe/i915).
    if [[ -d /dev/dri ]]; then
      for dev in /dev/dri/*; do
        [[ -e "$dev" ]] && GPU_ARGS+=(--dev-bind "$dev,$dev")
      done
    fi
    if [[ "${YOLO_HW_NVIDIA_ENABLE:-0}" == "1" ]]; then
      for dev in /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools \
                 /dev/nvidia0 /dev/nvidia1 /dev/nvidia2 /dev/nvidia3; do
        [[ -e "$dev" ]] && GPU_ARGS+=(--dev-bind "$dev,$dev")
      done
      if [[ -d /dev/nvidia-caps ]]; then
        for dev in /dev/nvidia-caps/*; do
          [[ -e "$dev" ]] && GPU_ARGS+=(--dev-bind "$dev,$dev")
        done
      fi
    fi
    if [[ "${YOLO_HW_AMD_GPU_ENABLE:-0}" == "1" ]]; then
      [[ -e /dev/kfd ]] && GPU_ARGS+=(--dev-bind "/dev/kfd,/dev/kfd")
    fi
    # Intel discrete GPUs (Arc / Arc Pro Battlemage) need no extra char devices
    # beyond /dev/dri/render*; xe/i915 expose all compute and media surfaces
    # through DRM render nodes.
  fi
fi

# Per-host extra bind paths (configured via Nix). The underlying llm-sandbox
# wrapper already filters non-existent paths, so a host that doesn't have
# the path simply contributes nothing.
EXTRA_PATH_ARGS=()
if [[ -n "${YOLO_EXTRA_RO_PATHS:-}" ]]; then
  while IFS= read -r _p; do
    [[ -n "$_p" ]] && EXTRA_PATH_ARGS+=(--ro "$_p")
  done <<< "$YOLO_EXTRA_RO_PATHS"
fi
if [[ -n "${YOLO_EXTRA_RW_PATHS:-}" ]]; then
  while IFS= read -r _p; do
    [[ -n "$_p" ]] && EXTRA_PATH_ARGS+=(--rw "$_p")
  done <<< "$YOLO_EXTRA_RW_PATHS"
fi

# Ollama models directory (read-only). Derived from services.ollama.models
# at Nix-eval time; empty on hosts where ollama is not enabled.
OLLAMA_ARGS=()
if [[ -n "${YOLO_OLLAMA_MODELS_DIR:-}" ]]; then
  OLLAMA_ARGS+=(--ro "$YOLO_OLLAMA_MODELS_DIR")
fi

LLM_SSH_KEY_ARGS=()
if [[ -n "${YOLO_LLM_SSH_KEY_PATH:-}" ]]; then
  # Resolve symlinks so we bind the real decrypted file. bwrap follows
  # symlinks on the host, but agenix swaps the symlink target across
  # generations and a stale source path would leave the sandbox holding
  # an empty bind on the next rebuild.
  _llm_key_real="$(readlink -f "$YOLO_LLM_SSH_KEY_PATH" 2>/dev/null || true)"
  if [[ -n "$_llm_key_real" && -e "$_llm_key_real" ]]; then
    LLM_SSH_KEY_ARGS+=(--ro-bind "$_llm_key_real,$YOLO_LLM_SSH_KEY_PATH")
    LLM_SSH_KEY_ARGS+=(--env "YOLO_LLM_SSH_KEY_PATH=$YOLO_LLM_SSH_KEY_PATH")
  else
    echo "warning: YOLO_LLM_SSH_KEY_PATH=$YOLO_LLM_SSH_KEY_PATH not readable; skipping bind" >&2
  fi
fi

BASE_ARGS=(
  --rw "${PWD}"
  --rw "${HOME}/.cache"
  --rw "${HOME}/.ivy2"
  "${SOCKET_ARGS[@]}"
  "${TMUX_BIND_ARGS[@]}"
  "${GPU_ARGS[@]}"
  "${LLM_SSH_KEY_ARGS[@]}"
  "${EXTRA_PATH_ARGS[@]}"
  "${OLLAMA_ARGS[@]}"
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

# Compose the system prompt fragments delivered to agents that accept an
# inline append (currently claude). Order: YOLO authorization → GPU
# availability (if --gpu took effect) → Nix-configured extras.
_yolo_prompt_base='YOLO mode is active. The user has pre-authorized destructive shell operations (rm, rm -rf, kill, git reset --hard, etc.) and will not be available to confirm. Proceed without asking for confirmation on such operations. Standard safety still applies to actions with broader blast radius (force-push to shared branches, deleting remote resources, sending external messages).'

_yolo_prompt_gpu=""
if [[ $GPU_MODE -eq 1 ]]; then
  _gpu_vendors=()
  [[ "${YOLO_HW_NVIDIA_ENABLE:-0}" == "1" ]] && _gpu_vendors+=("NVIDIA")
  [[ "${YOLO_HW_AMD_GPU_ENABLE:-0}" == "1" ]] && _gpu_vendors+=("AMD")
  [[ "${YOLO_HW_INTEL_GPU_ENABLE:-0}" == "1" ]] && _gpu_vendors+=("Intel")
  if (( ${#_gpu_vendors[@]} > 0 )); then
    _gpu_list=$(IFS=/; echo "${_gpu_vendors[*]}")
    _yolo_prompt_gpu="GPU access is enabled inside this sandbox (${_gpu_list}). /dev/dri, /sys, and /run/opengl-driver are bound — you can run GPU-accelerated workloads (llama.cpp/SYCL/ROCm/CUDA, vulkan, level-zero, OpenCL) directly without leaving the sandbox."
  fi
fi

_yolo_prompt_full="$_yolo_prompt_base"
if [[ -n "$_yolo_prompt_gpu" ]]; then
  _yolo_prompt_full+=$'\n\n'"$_yolo_prompt_gpu"
fi
if [[ -n "${YOLO_EXTRA_PROMPT:-}" ]]; then
  _yolo_prompt_full+=$'\n\n'"$YOLO_EXTRA_PROMPT"
fi

# Append claude state binds to EXTRA_ARGS, honoring $WORK_MODE.
# Mirrors the logic of the `claude` subcommand's claude bind block.
add_claude_binds() {
  if [[ $WORK_MODE -eq 1 ]]; then
    mkdir -p "${HOME}/.claude-work" "${HOME}/.claude-work-home" "${HOME}/.config/claude-work"
    touch "${HOME}/.claude-work-home/.claude.json"
    EXTRA_ARGS+=(
      --bind "${HOME}/.claude-work,${HOME}/.claude"
      --bind "${HOME}/.claude-work-home/.claude.json,${HOME}/.claude.json"
      --bind "${HOME}/.config/claude-work,${HOME}/.config/claude"
      --ro-bind "${HOME}/.claude/skills,${HOME}/.claude/skills"
      --ro-bind "${HOME}/.claude/plugins,${HOME}/.claude/plugins"
    )
  else
    EXTRA_ARGS+=(
      --rw "${HOME}/.claude"
      --rw "${HOME}/.claude.json"
      --rw "${HOME}/.config/claude"
    )
  fi
}

# Append codex state binds to EXTRA_ARGS, honoring $WORK_MODE.
# Mirrors the logic of the `codex` subcommand's codex bind block.
add_codex_binds() {
  if [[ $WORK_MODE -eq 1 ]]; then
    mkdir -p "${HOME}/.codex-work"
    local item src
    for item in config.toml AGENTS.md; do
      src="${HOME}/.codex/$item"
      if [[ -e "$src" ]]; then
        ln -sfn "$(readlink -f "$src")" "${HOME}/.codex-work/$item"
      fi
    done
    EXTRA_ARGS+=(
      --rw "${HOME}/.codex-work"
      --ro-bind "${HOME}/.codex/skills,${HOME}/.codex-work/skills"
      --env "CODEX_HOME=${HOME}/.codex-work"
    )
  else
    EXTRA_ARGS+=(
      --rw "${HOME}/.codex"
      --rw "${HOME}/.config/codex"
    )
  fi
}

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
        --ro-bind "${HOME}/.claude/skills,${HOME}/.claude/skills"
        --ro-bind "${HOME}/.claude/plugins,${HOME}/.claude/plugins"
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
    EXEC_CMD=(
      claude
      --permission-mode bypassPermissions
      --append-system-prompt "$_yolo_prompt_full"
      "${CMD_ARGS[@]}"
    )
    ;;

  codex)
    if [[ $WORK_MODE -eq 1 ]]; then
      mkdir -p "${HOME}/.codex-work"
      # Mirror shared config files into the work dir by symlinking to their
      # resolved nix-store targets (stable inside sandbox via the /nix/store
      # ro-bind). skills/ is a regular dir, so ro-bind it directly.
      for item in config.toml AGENTS.md; do
        src="${HOME}/.codex/$item"
        if [[ -e "$src" ]]; then
          ln -sfn "$(readlink -f "$src")" "${HOME}/.codex-work/$item"
        fi
      done
      EXTRA_ARGS+=(
        --rw "${HOME}/.codex-work"
        --ro-bind "${HOME}/.codex/skills,${HOME}/.codex-work/skills"
        --env "CODEX_HOME=${HOME}/.codex-work"
      )
    else
      EXTRA_ARGS+=(
        --rw "${HOME}/.codex"
        --rw "${HOME}/.config/codex"
      )
    fi
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
      EXTRA_ARGS+=(
        --bind "${HOME}/.gemini-work,${HOME}/.gemini"
        --ro-bind "${HOME}/.gemini/extensions,${HOME}/.gemini/extensions"
        --ro-bind "${HOME}/.gemini/skills,${HOME}/.gemini/skills"
      )
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

  shell)
    add_claude_binds
    add_codex_binds
    _user_shell="${SHELL:-/bin/sh}"
    _shell_name="$(basename "$_user_shell")"
    case "$_shell_name" in
      zsh)
        # Bind zsh rc files read-only; deliberately omit history files.
        # The llm-sandbox layer skips paths that don't exist on the host.
        for _f in .zshrc .zshenv .zprofile .zlogin .zlogout; do
          EXTRA_ARGS+=(--ro "${HOME}/$_f")
        done
        if [[ -n "${ZDOTDIR:-}" ]]; then
          EXTRA_ARGS+=(--ro "$ZDOTDIR")
        fi
        # Redirect history to an ephemeral tmpfs path inside the sandbox so
        # the shell can write/read freely without touching the real history.
        EXTRA_ARGS+=(--env "HISTFILE=/tmp/.zsh_history")
        ;;
      bash)
        for _f in .bashrc .bash_profile .bash_login .profile .inputrc; do
          EXTRA_ARGS+=(--ro "${HOME}/$_f")
        done
        EXTRA_ARGS+=(--env "HISTFILE=/tmp/.bash_history")
        ;;
      fish)
        EXTRA_ARGS+=(--ro "${HOME}/.config/fish")
        ;;
    esac
    EXEC_CMD=("$_user_shell" "${CMD_ARGS[@]}")
    ;;

  cmd)
    if [[ ${#CMD_ARGS[@]} -eq 0 ]]; then
      echo "Usage: yolo [flags...] cmd <program> [args...]" >&2; exit 1
    fi
    add_claude_binds
    add_codex_binds
    EXEC_CMD=("${CMD_ARGS[@]}")
    ;;

  *)
    echo "Unknown tool: $SUBCMD" >&2
    echo "Supported: claude, codex, copilot, gemini, vibe, opencode, shell, cmd" >&2
    exit 1
    ;;
esac

exec "$YOLO_LLM_SANDBOX" \
  "${BASE_ARGS[@]}" \
  "${EXTRA_ARGS[@]}" \
  -- "${EXEC_CMD[@]}"
