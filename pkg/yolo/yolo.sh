#!/usr/bin/env bash
# yolo - unified LLM tool launcher with llm-sandbox
#
# Required env vars (set by Nix wrapper):
#   YOLO_LLM_SANDBOX            - path to llm-sandbox binary
#   YOLO_NIX_LD                 - path to nix-ld binary (bound as /lib64/ld-linux-x86-64.so.2)
#   YOLO_JQ                     - path to jq binary
#   YOLO_CODEGRAPH_BIN          - path to codegraph binary (per-project index bootstrap)
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
: "${YOLO_CODEGRAPH_BIN:?must be set}"
: "${YOLO_COPILOT_DEFAULT_CONFIG:?must be set}"
: "${YOLO_COPILOT_BIN:?must be set}"

# PROFILE selects an isolated config namespace. Empty means the default
# profile: agents read their real home dirs (~/.claude, ~/.codex, ...).
# A non-empty NAME backs every agent's config with ~/.config/yolo/NAME/<agent>,
# bound onto the standard in-sandbox paths so agents need no profile-specific
# env. `--work`/`-w` is a backward-compatible alias for `--profile work`.
PROFILE=""
MOBILE_MODE=0
GPU_MODE=${YOLO_GPU_DEFAULT:-0}
# Refuse to launch with $PWD == $HOME by default: BASE_ARGS binds $PWD
# read-write, so running from the home directory would mount the entire home
# (credentials, keys, history) into the sandbox. --unsafe-share-home overrides.
UNSAFE_SHARE_HOME=0
# CodeGraph per-project index bootstrap is on by default; --no-cg opts out.
CG_MODE=1
# Audio (PipeWire/Pulse socket) is exposed by default so agents can play
# sound (e.g. completion notifications, TTS); --no-audio opts out. Binds
# self-skip on hosts without the sockets (headless), so this is a no-op there.
AUDIO_MODE=1
ENV_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile|-p)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Error: $1 requires a profile name" >&2; exit 1
      fi
      PROFILE="$2"; shift 2 ;;
    --work|-w) PROFILE="work"; shift ;;
    --mobile) MOBILE_MODE=1; shift ;;
    --gpu) GPU_MODE=1; shift ;;
    --no-gpu) GPU_MODE=0; shift ;;
    --no-cg) CG_MODE=0; shift ;;
    --audio) AUDIO_MODE=1; shift ;;
    --no-audio) AUDIO_MODE=0; shift ;;
    --unsafe-share-home) UNSAFE_SHARE_HOME=1; shift ;;
    --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
    -*) echo "Unknown flag: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

# Guard against path traversal / nesting: a profile name maps directly into a
# filesystem path under ~/.config/yolo, so restrict it to a safe charset.
if [[ -n "$PROFILE" && ( ! "$PROFILE" =~ ^[A-Za-z0-9._-]+$ || "$PROFILE" == "." || "$PROFILE" == ".." ) ]]; then
  echo "Error: invalid profile name '$PROFILE' (allowed: letters, digits, '.', '_', '-'; not '.' or '..')" >&2
  exit 1
fi

# Fail-safe: refuse to run with the working directory equal to $HOME. BASE_ARGS
# binds $PWD read-write into the sandbox, so launching from the home directory
# would mount the entire home — every credential, SSH/agenix key, and shell
# history — read-write, defeating the per-tool config isolation this wrapper
# exists to provide. Compare canonical paths so symlinked or trailing-slash
# forms still match. --unsafe-share-home opts out.
_pwd_real="$(readlink -f -- "${PWD}" 2>/dev/null || printf '%s' "${PWD}")"
_home_real="$(readlink -f -- "${HOME}" 2>/dev/null || printf '%s' "${HOME}")"
if [[ "$_pwd_real" == "$_home_real" && $UNSAFE_SHARE_HOME -ne 1 ]]; then
  echo "Error: refusing to run yolo from \$HOME ($_home_real)." >&2
  echo "       \$PWD is bound read-write into the sandbox, so this would expose your" >&2
  echo "       entire home directory (credentials, keys, history) and defeat profile" >&2
  echo "       isolation. cd into a project subdirectory, or pass --unsafe-share-home" >&2
  echo "       to override." >&2
  exit 1
fi

# Host-side backing directory for an agent within the active named profile.
profile_dir() { printf '%s/.config/yolo/%s/%s' "${HOME}" "${PROFILE}" "$1"; }

# A profile's writable home is bound onto the agent's real home dir, then the
# HM-managed assets (settings.json, CLAUDE.md, skills, ...) are re-shared
# read-only on top via --ro-bind. bwrap creates each --ro-bind destination by
# following whatever entry already exists at that path. Earlier yolo revisions
# left absolute-store symlinks at those paths in the profile home; pointing
# into a home-manager generation that later gets garbage-collected, they dangle
# and bwrap aborts the whole launch with
#   Can't create file at <dest>: No such file or directory
# Drop any leftover symlink at the re-shared leaves so bwrap creates fresh
# mountpoints. An agent's genuine writable state at these exact leaves is never
# a symlink, so this only clears stale re-share artifacts.
clear_reshare_leftovers() {
  local base="$1"; shift
  local leaf
  for leaf in "$@"; do
    [[ -L "$base/$leaf" ]] && rm -f "$base/$leaf"
  done
}

if [[ $MOBILE_MODE -eq 1 ]]; then
  if [[ -n "${TMUX:-}" ]]; then
    tmux set-window-option window-size manual
    tmux resize-window -x 59 -y 33
  else
    echo "warning: --mobile requires tmux, ignoring" >&2
  fi
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: yolo [--profile NAME|-p NAME] [--work] [--mobile] [--gpu|--no-gpu] [--no-cg] [--audio|--no-audio] [--unsafe-share-home] [--env KEY=VAL]... <claude|codex|copilot|vibe|opencode|pi|shell|cmd> [args...]" >&2
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

# Audio: expose the PipeWire native socket and the PulseAudio-compat socket
# (covers pw-play / paplay / mpv / ffplay etc.) so agents can play sound. Both
# sockets are bidirectional, so this also permits capture. The sockets are
# bound read-write at their host paths; the llm-sandbox layer skips any that
# don't exist (headless hosts). Not binding /dev/snd on purpose: PipeWire owns
# the devices, so socket routing is the correct path. --no-audio disables.
AUDIO_ARGS=()
if [[ $AUDIO_MODE -eq 1 ]]; then
  _xrd="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  AUDIO_ARGS+=(--rw "$_xrd/pipewire-0")
  AUDIO_ARGS+=(--rw "$_xrd/pulse/native")
  AUDIO_ARGS+=(--ro "${HOME}/.config/pulse/cookie")
  AUDIO_ARGS+=(--env "PULSE_SERVER=unix:$_xrd/pulse/native")
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
  "${AUDIO_ARGS[@]}"
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

# Compose the system prompt fragments delivered to agents that accept an inline
# append. Two variants:
#   _yolo_prompt_full  = YOLO authorization + GPU availability + Nix extras
#                        (for agents with a permission/confirmation system, e.g.
#                        claude — the authorization tells them not to prompt).
#   _yolo_prompt_extra = GPU availability + Nix extras only (no authorization)
#                        for agents with no permission system, where the "don't
#                        ask for confirmation" text is meaningless (e.g. pi).
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

# Non-authorization fragments (GPU + extras), joined with blank lines.
_yolo_prompt_extra=""
if [[ -n "$_yolo_prompt_gpu" ]]; then
  _yolo_prompt_extra="$_yolo_prompt_gpu"
fi
if [[ -n "${YOLO_EXTRA_PROMPT:-}" ]]; then
  [[ -n "$_yolo_prompt_extra" ]] && _yolo_prompt_extra+=$'\n\n'
  _yolo_prompt_extra+="$YOLO_EXTRA_PROMPT"
fi

# Full prompt = authorization + the non-auth fragments.
_yolo_prompt_full="$_yolo_prompt_base"
if [[ -n "$_yolo_prompt_extra" ]]; then
  _yolo_prompt_full+=$'\n\n'"$_yolo_prompt_extra"
fi

# For named profiles, each agent's config is backed by a dir under
# ~/.config/yolo/<profile>/<agent>/ and bound onto the agent's standard
# in-sandbox path, so inside the sandbox every tool reads its usual location.
# The default profile (empty $PROFILE) binds the real home dirs directly.
# Nix-managed, profile-independent assets (skills/plugins/extensions, codex
# config) are shared read-only from the main profile.

# claude: ~/.claude (state), ~/.claude.json (auth), ~/.config/claude (settings).
add_claude_binds() {
  if [[ -n "$PROFILE" ]]; then
    local A; A="$(profile_dir claude)"
    mkdir -p "$A/home" "$A/config"
    clear_reshare_leftovers "$A/home" skills plugins commands agents settings.json CLAUDE.md
    # claude requires .claude.json to be valid JSON; an empty file aborts it
    # with a parse error. Seed an empty object only when missing/empty.
    [[ -s "$A/home.json" ]] || printf '{}\n' > "$A/home.json"
    EXTRA_ARGS+=(
      --bind "$A/home,${HOME}/.claude"
      --bind "$A/home.json,${HOME}/.claude.json"
      --bind "$A/config,${HOME}/.config/claude"
      --ro-bind "${HOME}/.claude/skills,${HOME}/.claude/skills"
      --ro-bind "${HOME}/.claude/plugins,${HOME}/.claude/plugins"
      # commands/ + agents/ are HM-managed (programs.claude-code.{commands,
      # agents}) and carry the ledger-flake slash commands (plan:start, …)
      # and subagents. settings.json + CLAUDE.md are likewise HM-managed and
      # profile-independent. All four are masked by the $A/home bind above,
      # so re-share them read-only from the main profile.
      --ro-bind "${HOME}/.claude/commands,${HOME}/.claude/commands"
      --ro-bind "${HOME}/.claude/agents,${HOME}/.claude/agents"
      --ro-bind "${HOME}/.claude/settings.json,${HOME}/.claude/settings.json"
      --ro-bind "${HOME}/.claude/CLAUDE.md,${HOME}/.claude/CLAUDE.md"
    )
  else
    EXTRA_ARGS+=(
      --rw "${HOME}/.claude"
      --rw "${HOME}/.claude.json"
      --rw "${HOME}/.config/claude"
    )
  fi
}

# codex: ~/.codex (CODEX_HOME default) + ~/.config/codex. Shared read-only from
# the main profile: config.toml, AGENTS.md, skills.
add_codex_binds() {
  if [[ -n "$PROFILE" ]]; then
    local A item; A="$(profile_dir codex)"
    mkdir -p "$A/home" "$A/config"
    # Materialize the profile's ~/.codex/config.toml as a writable copy of the
    # main (HM) config with $PWD pre-trusted; bound in via $A/home below. The
    # host ~/.codex is left untouched in profile mode.
    ensure_codex_config "$A/home/config.toml" "${HOME}/.codex/config.toml" "${PWD}"
    clear_reshare_leftovers "$A/home" AGENTS.md skills
    EXTRA_ARGS+=(
      --bind "$A/home,${HOME}/.codex"
      --bind "$A/config,${HOME}/.config/codex"
    )
    # config.toml now comes from $A/home (writable, trusted); only the remaining
    # HM-managed assets are shared read-only from the main profile.
    for item in AGENTS.md skills; do
      EXTRA_ARGS+=(--ro-bind "${HOME}/.codex/$item,${HOME}/.codex/$item")
    done
  else
    # Default profile shares the real ~/.codex: replace the immutable HM
    # config.toml symlink in place with a writable, $PWD-trusted copy so codex
    # finds the project trusted and never needs the failing trust write.
    ensure_codex_config "${HOME}/.codex/config.toml" "${HOME}/.codex/config.toml" "${PWD}"
    EXTRA_ARGS+=(
      --rw "${HOME}/.codex"
      --rw "${HOME}/.config/codex"
    )
  fi
}

# vibe: ~/.vibe (config) + ~/.local/share/vibe (data).
add_vibe_binds() {
  if [[ -n "$PROFILE" ]]; then
    local A; A="$(profile_dir vibe)"
    mkdir -p "$A/config" "$A/data"
    EXTRA_ARGS+=(
      --bind "$A/config,${HOME}/.vibe"
      --bind "$A/data,${HOME}/.local/share/vibe"
    )
  else
    mkdir -p "${HOME}/.vibe" "${HOME}/.local/share/vibe"
    EXTRA_ARGS+=(
      --rw "${HOME}/.vibe"
      --rw "${HOME}/.local/share/vibe"
    )
  fi
}

# opencode: ~/.config/opencode (config) + ~/.local/share/opencode (data).
add_opencode_binds() {
  if [[ -n "$PROFILE" ]]; then
    local A; A="$(profile_dir opencode)"
    mkdir -p "$A/config" "$A/data"
    EXTRA_ARGS+=(
      --bind "$A/config,${HOME}/.config/opencode"
      --bind "$A/data,${HOME}/.local/share/opencode"
    )
  else
    EXTRA_ARGS+=(
      --rw "${HOME}/.config/opencode"
      --rw "${HOME}/.local/share/opencode"
    )
  fi
}

# copilot: backed by ~/.copilot (in-sandbox), seeded on the host side. Sets the
# global COPILOT_CONFIG_DIR (the in-sandbox path) consumed by the `copilot`
# subcommand, and seeds config (trusted folder + defaults) on the host backing
# dir so copilot is usable as a secondary agent launched from another tool.
add_copilot_binds() {
  local host_dir
  if [[ -n "$PROFILE" ]]; then
    local A; A="$(profile_dir copilot)"
    mkdir -p "$A/home"
    host_dir="$A/home"
    EXTRA_ARGS+=(--bind "$A/home,${HOME}/.copilot")
  else
    host_dir="${HOME}/.copilot"
    EXTRA_ARGS+=(--rw "${HOME}/.copilot")
  fi
  EXTRA_ARGS+=(--ro "${HOME}/.config/gh")
  ensure_copilot_config "$host_dir" "${PWD}"
  COPILOT_CONFIG_DIR="${HOME}/.copilot"
}

# pi: ~/.pi (state + ~/.pi/agent config). HM-managed assets (settings.json,
# AGENTS.md, skills, optional extensions) are shared read-only from the main
# profile, like codex. Pi has no built-in MCP — its pi-mcp-adapter package
# reads the shared registry at ~/.config/mcp/mcp.json (written by programs.mcp),
# so bind that read-only too.
add_pi_binds() {
  EXTRA_ARGS+=(--ro "${HOME}/.config/mcp")
  # Provider + web-search API keys: agenix secret files, read-only. The pi
  # wrapper (piWrapped) reads /run/agenix/<name> at launch. Missing files are
  # skipped by the llm-sandbox layer (hosts without these secrets).
  for _sec in openrouter vercel exa brave firecrawl; do
    EXTRA_ARGS+=(--ro "/run/agenix/$_sec")
  done
  # rpiv-web-tools writable config (provider selection / SearXNG URL).
  EXTRA_ARGS+=(--rw "${HOME}/.config/rpiv-web-tools")
  if [[ -n "$PROFILE" ]]; then
    local A item; A="$(profile_dir pi)"
    mkdir -p "$A/home/agent"
    clear_reshare_leftovers "$A/home" agent/settings.json agent/AGENTS.md agent/skills agent/extensions agent/mcp.json
    EXTRA_ARGS+=(--bind "$A/home,${HOME}/.pi")
    # Share the HM-managed (read-only, store-symlinked) assets from the main
    # profile; non-existent paths are filtered by the llm-sandbox layer.
    for item in agent/settings.json agent/AGENTS.md agent/skills agent/extensions agent/mcp.json; do
      EXTRA_ARGS+=(--ro-bind "${HOME}/.pi/$item,${HOME}/.pi/$item")
    done
  else
    EXTRA_ARGS+=(--rw "${HOME}/.pi")
  fi
}

# Bind every supported agent's config so that whichever tool is launched can
# in turn drive any of the others (e.g. claude shelling out to codex/opencode),
# each scoped to the active $PROFILE.
add_all_agent_binds() {
  add_claude_binds
  add_codex_binds
  add_copilot_binds
  add_vibe_binds
  add_opencode_binds
  add_pi_binds
}

# codex gates its interactive directory-trust screen on persisted trust read
# from ~/.codex/config.toml (projects."<cwd>".trust_level == "trusted"), which it
# reads from the file early — a CLI `-c` override does NOT feed the gate. It
# persists trust on accept via an atomic "config/batchWrite". Our config.toml is
# an immutable Home-Manager nix-store symlink, so codex can neither see the
# project trusted nor write trust ("Failed to set trust … config/batchWrite
# failed"). bwrap also cannot bind a writable file over a symlink path, so we
# materialize a real, writable config.toml = (HM base) + a trust table for $PWD.
#
# In the default profile out_file == base_file == ~/.codex/config.toml, so this
# replaces the HM symlink on the host with a writable copy. That is self-healing:
# a home-manager rebuild restores the symlink, and the next launch re-creates the
# writable copy. In a named profile out_file is the profile's own backing file,
# so the host ~/.codex is untouched. Mirrors the copilot pre-trust.
#   $1 = out_file  (writable config.toml to produce / bind into the sandbox)
#   $2 = base_file (HM config.toml to copy settings from; a store symlink)
#   $3 = trusted_dir ($PWD)
ensure_codex_config() {
  local out_file="$1" base_file="$2" trusted_dir="$3"
  local header tmp
  header="[projects.\"${trusted_dir}\"]"

  # Idempotent: a real (non-symlink) out_file that already trusts $PWD is done —
  # avoids rewriting on every launch into an already-trusted directory.
  if [[ -f "$out_file" && ! -L "$out_file" ]] && grep -qF "$header" "$out_file"; then
    return 0
  fi

  mkdir -p "$(dirname "$out_file")"
  tmp="$(mktemp)"
  # Capture the base config (cat follows the HM store symlink) before any
  # replacement, so the in-place out_file == base_file case keeps prior content.
  [[ -e "$base_file" ]] && cat -- "$base_file" > "$tmp" 2>/dev/null
  # Append the trust table only when absent. A fresh [projects."<dir>"] table is
  # always valid to append: TOML headers are absolute and the base never has it.
  grep -qF "$header" "$tmp" 2>/dev/null \
    || printf '\n%s\ntrust_level = "trusted"\n' "$header" >> "$tmp"
  rm -f "$out_file"          # drop the immutable HM symlink (or a stale copy)
  mv "$tmp" "$out_file"
  chmod u+w "$out_file"
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

  # Write only when the result differs from what is already on disk. Because
  # add_copilot_binds runs on every yolo launch (so copilot is usable as a
  # secondary agent), this keeps non-copilot launches from rewriting the file
  # or bumping its mtime once $PWD is already trusted and defaults are applied.
  if [[ -f "$config_file" ]] && cmp -s "$tmp_config" "$config_file"; then
    rm -f "$tmp_config"
  else
    mv "$tmp_config" "$config_file"
  fi
}

# CodeGraph per-project index bootstrap. The codegraph MCP server (wired into
# every agent CLI) reads .codegraph/codegraph.db in the project root, but never
# creates it — building the per-project index is an explicit step. On the first
# agent launch in a project we initialize and index so the agent's codegraph_*
# tools work immediately; later launches find a populated DB and skip in one
# cheap `status` call. The on-host index lives in $PWD (rw-bound into the
# sandbox) and is shared with the in-sandbox `serve` process. --no-cg opts out.
#
# `codegraph status --json` reports {"initialized":false} when no DB exists.
# Two partial states also need indexing: a bare `init` (no -i) leaves the DB
# initialized with fileCount==0, and `init -i` refuses to re-index an already
# initialized project. So we drive init and index as separate steps keyed off
# (initialized, fileCount) rather than relying on `init -i`'s one-shot.
maybe_init_codegraph() {
  [[ $CG_MODE -eq 1 ]] || return 0
  [[ -x "$YOLO_CODEGRAPH_BIN" ]] || return 0

  local initialized file_count
  read -r initialized file_count < <(
    "$YOLO_CODEGRAPH_BIN" status --json 2>/dev/null \
      | "$YOLO_JQ" -r '"\(.initialized // false) \(.fileCount // 0)"' 2>/dev/null
  )

  # DB already exists and is populated: refresh it incrementally so the agent
  # sees changes made since the last index, then proceed. `sync` diffs against
  # the last index and is cheap; a failure is non-fatal (use the stale index).
  if [[ "$initialized" == "true" && "${file_count:-0}" -gt 0 ]]; then
    echo "yolo: syncing CodeGraph index for ${PWD}…" >&2
    "$YOLO_CODEGRAPH_BIN" sync >&2 \
      || echo "warning: codegraph sync failed; continuing with the existing index" >&2
    return 0
  fi

  echo "yolo: building CodeGraph index for ${PWD} (one-time; pass --no-cg to skip)…" >&2
  if [[ "$initialized" != "true" ]]; then
    if ! "$YOLO_CODEGRAPH_BIN" init >&2; then
      echo "warning: codegraph init failed; launching without a code index" >&2
      return 0
    fi
  fi
  "$YOLO_CODEGRAPH_BIN" index >&2 \
    || echo "warning: codegraph index failed; launching without a code index" >&2
}

# Agent subcommands run an MCP-enabled CLI that can use the codegraph server;
# shell/cmd do not, so they skip the index bootstrap.
case "$SUBCMD" in
  claude|codex|copilot|vibe|opencode|pi) maybe_init_codegraph ;;
esac

case "$SUBCMD" in
  claude)
    add_all_agent_binds
    EXEC_CMD=(
      claude
      --permission-mode bypassPermissions
      --append-system-prompt "$_yolo_prompt_full"
      "${CMD_ARGS[@]}"
    )
    ;;

  codex)
    add_all_agent_binds
    EXEC_CMD=(codex --dangerously-bypass-approvals-and-sandbox --search "${CMD_ARGS[@]}")
    ;;

  copilot)
    add_all_agent_binds

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

  vibe)
    add_all_agent_binds
    EXEC_CMD=(vibe --agent auto-approve "${CMD_ARGS[@]}")
    ;;

  opencode)
    add_all_agent_binds
    EXEC_CMD=(opencode "${CMD_ARGS[@]}")
    ;;

  pi)
    add_all_agent_binds
    # Pi has no permission/confirmation system by design, so the YOLO
    # "don't ask for confirmation" authorization is meaningless to it. Only
    # append the non-authorization context (GPU availability, host extras), and
    # only when there is any.
    pi_prompt_args=()
    [[ -n "$_yolo_prompt_extra" ]] && pi_prompt_args+=(--append-system-prompt "$_yolo_prompt_extra")
    EXEC_CMD=(pi "${pi_prompt_args[@]}" "${CMD_ARGS[@]}")
    ;;

  shell)
    add_all_agent_binds
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
    add_all_agent_binds
    EXEC_CMD=("${CMD_ARGS[@]}")
    ;;

  *)
    echo "Unknown tool: $SUBCMD" >&2
    echo "Supported: claude, codex, copilot, vibe, opencode, pi, shell, cmd" >&2
    exit 1
    ;;
esac

exec "$YOLO_LLM_SANDBOX" \
  "${BASE_ARGS[@]}" \
  "${EXTRA_ARGS[@]}" \
  -- "${EXEC_CMD[@]}"
