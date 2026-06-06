# Thin consumer wrapper around the portable LLM coding-agent harness
# (inputs.cq.homeManagerModules.dev-llm, see 7mind/cq nix/hm/dev-llm.nix). Imports
# that module and wires THIS host's facts (GPU flags, rootless-Podman socket,
# ollama models dir) from the NixOS system config (outerConfig), which the
# portable module cannot reference.
# Opencode/Copilot/Vibe and local-model provider config live in ./dev-opencode.nix.
{ config, lib, cfg-meta, outerConfig, inputs, ... }:
let
  cfg = config.smind.hm.dev.llm;

  rootlessPodmanEnabled =
    cfg-meta.isLinux
    && (outerConfig.smind.containers.docker.enable or false)
    && (outerConfig.smind.containers.docker.rootless.enable or false);
  rootlessPodmanSocketPathValue = outerConfig.smind.containers.docker.rootless.llmSocketPath or null;
  rootlessPodmanSocketUriValue = outerConfig.smind.containers.docker.rootless.llmSocketUri or null;
in
{
  imports = [ inputs.cq.homeManagerModules.dev-llm ];

  config = lib.mkIf cfg.enable {
    # GPU hardware flags for the yolo `--gpu` sandbox bind.
    smind.hm.dev.llm.yolo.gpu = {
      nvidiaEnable = outerConfig.smind.hw.nvidia.enable or false;
      amdEnable = outerConfig.smind.hw.amd.gpu.enable or false;
      intelEnable = outerConfig.smind.hw.intel.gpu.enable or false;
    };

    # Bind the host's ollama models dir (services.ollama.models) only when
    # ollama is enabled on this host; otherwise skip the bind.
    smind.hm.dev.llm.ollamaModelsDir =
      if (outerConfig.services.ollama.enable or false)
      then outerConfig.services.ollama.models
      else null;

    # Rootless-Podman socket: fail-fast if enabled but the socket path/uri
    # were not provided by the host config.
    smind.hm.dev.llm.podman.socketPath =
      if rootlessPodmanEnabled then
        (if rootlessPodmanSocketPathValue == null
        then throw "smind.containers.docker.rootless.llmSocketPath must be set when rootless Podman is enabled"
        else rootlessPodmanSocketPathValue)
      else null;
    smind.hm.dev.llm.podman.socketUri =
      if rootlessPodmanEnabled then
        (if rootlessPodmanSocketUriValue == null
        then throw "smind.containers.docker.rootless.llmSocketUri must be set when rootless Podman is enabled"
        else rootlessPodmanSocketUriValue)
      else null;
  };
}
