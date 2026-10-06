# Supplies host-only facts that the portable harness module cannot access.
# The legacy cq wrapper (inputs.cq.homeManagerModules.dev-llm) is removed;
# cq4 is not wired yet. The harness itself comes from ponygirls.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.smind.hm.dev.llm;
  host = config.smind.hm.globals;

  gpu = {
    nvidia = host.hw.nvidia.enable;
    amd = host.hw.amd.gpu.enable;
    intel = host.hw.intel.gpu.enable;
  };
  gpuEnabled = gpu.nvidia || gpu.amd || gpu.intel;

  ollamaModelsDir =
    if host.ollama.enable
    then host.ollama.modelsDir
    else null;
  crawl4aiToken = host.age.secrets.crawl4ai-api-token or null;
  hasCrawl4aiToken = crawl4aiToken != null;
in
{
  imports = [ inputs.ponygirls.homeManagerModules.dev-llm ];

  config = lib.mkIf cfg.enable {
    smind.hm.dev.llm.extraSkills = lib.mkIf cfg.yolo.vm.enable {
      local-test-vms = builtins.readFile ./skills/local-test-vms/SKILL.md;
    };

    # Register the codegraph MCP tools directly in Pi instead of behind
    # pi-mcp-adapter's mcp() proxy, so its tools load eagerly into context.
    # Scoped to this server (not `true`) so a future verbose MCP server stays
    # proxied. The legacy cq `ledger` server is not registered until cq4.
    smind.hm.dev.llm.pi.mcpDirectTools = [ "codegraph" ]
      ++ lib.optional hasCrawl4aiToken "crawl4ai"; # "ledger"

    # Same endpoint for Claude Code, Codex, and Pi. The token stays in the
    # agenix file: yolo exports it as CRAWL4AI_API_TOKEN, and the proxy also
    # accepts the file path when the harness is launched outside yolo.
    smind.hm.dev.llm.crawl4ai = lib.mkIf hasCrawl4aiToken {
      enable = true;
      url = "http://crawl4ai.pgtr.7mind.io:11235/mcp/sse";
      tokenFile = crawl4aiToken.path;
    };
    smind.hm.dev.llm.yolo.secretSessionVariables = lib.mkIf hasCrawl4aiToken {
      CRAWL4AI_API_TOKEN = crawl4aiToken.path;
    };
    smind.hm.dev.llm.memorySections = lib.mkIf hasCrawl4aiToken [
      ''
        ## Web fetch and screenshots

        The `crawl4ai` MCP server fetches public pages and takes screenshots
        (tools: `md`, `html`, `screenshot`, `pdf`, `crawl`). It runs on
        `crawl4ai.pgtr.7mind.io` and cannot open connections to this host or
        to other machines on local networks; requests to private addresses
        fail at the network boundary. Do not send it credentials or internal
        URLs. `execute_js` and crawler hooks are disabled on the server.
      ''
    ];

    # Suppress Codex's "switch to a lower tier model" nudge on the rate-limit
    # (low-token) basis — "Approaching rate limits / uses fewer credits for
    # upcoming turns". Same preference the nudge's own "Keep current model
    # (never show again)" writes. The slow-response variant ("Giving this
    # request a little extra thought / retry with a faster model", prompt id
    # `safety-buffering-prompt`) has no suppression switch in codex 0.159.2;
    # its display is server-driven (x-codex-safety-buffering-* headers).
    programs.codex.settings.notice.hide_rate_limit_model_nudge = true;

    # Pin the Pi default model (matches the ponygirls module default; pinned
    # here so an upstream default change cannot drift it silently).
    smind.hm.dev.llm.models.pi.model = "mimo-v2.6-pro";

    # Let Pi subagents use any model (spawn_agent model overrides and gate
    # reviewers). Writes "allowedModels": null to ~/.pi/agent/subagents-policy.json,
    # which home-manager then owns as a read-only store symlink (hand-maintained
    # repos/nesting/gate keys in that file are replaced, not merged).
    smind.hm.dev.llm.pi.subagentsAllowAllModels = true;

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
