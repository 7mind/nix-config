# Supplies host-only facts that the portable cq module cannot access.
{ config, lib, pkgs, outerConfig, inputs, ... }:
let
  cfg = config.smind.hm.dev.llm;

  gpu = {
    nvidia = outerConfig.smind.hw.nvidia.enable or false;
    amd = outerConfig.smind.hw.amd.gpu.enable or false;
    intel = outerConfig.smind.hw.intel.gpu.enable or false;
  };
  gpuEnabled = gpu.nvidia || gpu.amd || gpu.intel;

  ollamaModelsDir =
    if (outerConfig.services.ollama.enable or false)
    then outerConfig.services.ollama.modelsDir
    else null;
in
{
  imports = [ inputs.cq.homeManagerModules.dev-llm ];

  config = lib.mkIf cfg.enable {
    smind.hm.dev.llm.extraSkills = lib.mkIf cfg.yolo.vm.enable {
      local-test-vms = builtins.readFile ./skills/local-test-vms/SKILL.md;
    };

    # Register the codegraph + ledger MCP tools directly in Pi instead of
    # behind pi-mcp-adapter's mcp() proxy, so all their tools load eagerly
    # into context. Scoped to these two servers (not `true`) so a future
    # verbose MCP server stays proxied.
    smind.hm.dev.llm.pi.mcpDirectTools = [ "codegraph" "ledger" ];

    home.activation.removeObsoleteClaudePluginBackup = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      backup=${lib.escapeShellArg "${config.programs.claude-code.configDir}/skills/claude-code-home-manager.hmbak"}
      manifest="$backup/.claude-plugin/plugin.json"
      if [ -f "$manifest" ] && ${pkgs.jq}/bin/jq -e '.name == "claude-code-home-manager"' "$manifest" >/dev/null; then
        rm -rf "$backup"
      fi
    '';

    # GPU passthrough for the yolo sandbox, wired from this host's detected GPU
    # vendor(s) (cq no longer builds this in; the `--gpu`/`--no-gpu`/`--no-dev`
    # CLI flags are gone — GPU is bound statically whenever a vendor is present,
    # and `yolo --disable=gpu` (or `=amd`/`=nvidia`) drops the tagged binds AND
    # their prompt note for a run).
    #   - device nodes are `--dev-bind`'d, each tagged "gpu" + vendor;
    #   - the non-device GPU userspace (/run/opengl-driver) and device
    #     enumeration tree (/sys) are ro-bound;
    #   - the availability notes are appended to both agents' system prompts.
    # /dev/dri is a directory, so it covers every render node (the old built-in
    # code iterated /dev/dri/*). Missing device paths are skipped at runtime.
    smind.hm.dev.llm.yolo.extraDevicePaths =
      lib.optionals gpuEnabled [ { path = "/dev/dri"; tags = [ "gpu" ]; } ]
      ++ lib.optionals gpu.amd [ { path = "/dev/kfd"; tags = [ "gpu" "amd" ]; } ]
      ++ lib.optionals gpu.nvidia (map (p: { path = p; tags = [ "gpu" "nvidia" ]; }) [
        "/dev/nvidiactl"
        "/dev/nvidia-modeset"
        "/dev/nvidia-uvm"
        "/dev/nvidia-uvm-tools"
        "/dev/nvidia0"
        "/dev/nvidia-caps"
      ]);

    smind.hm.dev.llm.yolo.extraReadOnlyPaths =
      lib.optionals gpuEnabled [ "/run/opengl-driver" "/sys" ]
      ++ lib.optional (ollamaModelsDir != null) ollamaModelsDir;

    # GPU availability notes (replace cq's deleted built-in note); appended
    # after the module's YOLO/SSH/GitHub notes. target "*" → Claude and Pi.
    # One generic (vendor-neutral) note plus one note per detected vendor — a
    # host with both NVIDIA and AMD (e.g. nvidia+rocm) gets both vendor notes.
    # Each carries the "gpu" tag (vendor notes also the vendor tag) so
    # `yolo --disable=gpu` (or `=amd`/`=nvidia`) hides the note with its devices.
    smind.hm.dev.llm.yolo.promptExtensions = [
      {
        prompt = "GPU access is enabled inside this sandbox. /dev/dri, /sys, and /run/opengl-driver are bound — you can run GPU-accelerated workloads (llama.cpp, Vulkan, OpenCL) directly without leaving the sandbox; see the vendor-specific note for the native compute stack.";
        target = "*";
        tags = [ "gpu" ];
        when = gpuEnabled;
      }
      {
        prompt = "NVIDIA GPU present: the /dev/nvidia* device nodes are bound — run CUDA workloads (and the llama.cpp CUDA backend) directly.";
        target = "*";
        tags = [ "gpu" "nvidia" ];
        when = gpu.nvidia;
      }
      {
        prompt = "AMD GPU present: /dev/kfd is bound — run ROCm/HIP workloads (and the llama.cpp ROCm/HIP backend) directly.";
        target = "*";
        tags = [ "gpu" "amd" ];
        when = gpu.amd;
      }
      {
        prompt = "Intel GPU present: the render nodes under /dev/dri are bound — run SYCL / oneAPI Level-Zero workloads (and the llama.cpp SYCL backend) directly.";
        target = "*";
        tags = [ "gpu" "intel" ];
        when = gpu.intel;
      }
    ]
    ++ lib.optional (ollamaModelsDir != null) {
      prompt = "The host's Ollama model store is bound read-only at ${ollamaModelsDir} inside the sandbox — already-pulled models are reusable from there (e.g. set OLLAMA_MODELS to that path) instead of re-downloading.";
      target = "*";
      tags = [ "ollama" ];
      when = true;
    };
  };
}
