{
  lib,
  pkgs,
  llm-sandbox,
  nix-ld,
  jq,
  codegraph,
  github-copilot-cli,
  copilotConfig ? "/dev/null",
  copilotModel ? "gpt-5.4",
  copilotReasoningEffort ? "xhigh",
  podmanSocketPath ? null,
  podmanSocketUri ? null,
  hwNvidiaEnable ? false,
  hwAmdGpuEnable ? false,
  hwIntelGpuEnable ? false,
  llmSshKeyPath ? null,
  gpuByDefault ? false,
  extraReadOnlyPaths ? [ ],
  extraReadWritePaths ? [ ],
  ollamaModelsDir ? null,
  extraPromptFragments ? [ ],
}:

let
  yoloScript = ./yolo.sh;
  podmanExports = lib.optionalString (podmanSocketPath != null) ''
    export YOLO_PODMAN_SOCKET_PATH=${lib.escapeShellArg podmanSocketPath}
    export YOLO_PODMAN_SOCKET_URI=${lib.escapeShellArg podmanSocketUri}
  '';
  llmSshKeyExports = lib.optionalString (llmSshKeyPath != null) ''
    export YOLO_LLM_SSH_KEY_PATH=${lib.escapeShellArg llmSshKeyPath}
  '';
  ollamaExports = lib.optionalString (ollamaModelsDir != null) ''
    export YOLO_OLLAMA_MODELS_DIR=${lib.escapeShellArg ollamaModelsDir}
  '';
  # Newline-joined path lists: paths cannot contain newlines, so this is
  # unambiguous and survives shell quoting. yolo.sh splits on newline.
  joinPaths = paths: lib.concatStringsSep "\n" paths;
  extraRoExports = lib.optionalString (extraReadOnlyPaths != [ ]) ''
    export YOLO_EXTRA_RO_PATHS=${lib.escapeShellArg (joinPaths extraReadOnlyPaths)}
  '';
  extraRwExports = lib.optionalString (extraReadWritePaths != [ ]) ''
    export YOLO_EXTRA_RW_PATHS=${lib.escapeShellArg (joinPaths extraReadWritePaths)}
  '';
  promptExports = lib.optionalString (extraPromptFragments != [ ]) ''
    export YOLO_EXTRA_PROMPT=${lib.escapeShellArg (lib.concatStringsSep "\n\n" extraPromptFragments)}
  '';
in
pkgs.writeShellScriptBin "yolo" ''
  export YOLO_LLM_SANDBOX="${llm-sandbox}/bin/llm-sandbox"
  export YOLO_NIX_LD="${nix-ld}/bin/nix-ld"
  export YOLO_JQ="${jq}/bin/jq"
  export YOLO_CODEGRAPH_BIN="${codegraph}/bin/codegraph"
  export YOLO_COPILOT_DEFAULT_CONFIG="${copilotConfig}"
  export YOLO_COPILOT_BIN="${github-copilot-cli}/bin/copilot"
  export YOLO_COPILOT_MODEL=${lib.escapeShellArg copilotModel}
  export YOLO_COPILOT_REASONING_EFFORT=${lib.escapeShellArg copilotReasoningEffort}
  export YOLO_HW_NVIDIA_ENABLE=${if hwNvidiaEnable then "1" else "0"}
  export YOLO_HW_AMD_GPU_ENABLE=${if hwAmdGpuEnable then "1" else "0"}
  export YOLO_HW_INTEL_GPU_ENABLE=${if hwIntelGpuEnable then "1" else "0"}
  export YOLO_GPU_DEFAULT=${if gpuByDefault then "1" else "0"}
  ${podmanExports}
  ${llmSshKeyExports}
  ${ollamaExports}
  ${extraRoExports}
  ${extraRwExports}
  ${promptExports}
  exec bash ${yoloScript} "$@"
''
