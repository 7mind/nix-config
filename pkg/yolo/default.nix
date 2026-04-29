{
  lib,
  pkgs,
  llm-sandbox,
  nix-ld,
  jq,
  github-copilot-cli,
  copilotConfig ? "/dev/null",
  copilotModel ? "gpt-5.4",
  copilotReasoningEffort ? "xhigh",
  podmanSocketPath ? null,
  podmanSocketUri ? null,
  hwNvidiaEnable ? false,
  hwAmdGpuEnable ? false,
}:

let
  yoloScript = ./yolo.sh;
  podmanExports = lib.optionalString (podmanSocketPath != null) ''
    export YOLO_PODMAN_SOCKET_PATH=${lib.escapeShellArg podmanSocketPath}
    export YOLO_PODMAN_SOCKET_URI=${lib.escapeShellArg podmanSocketUri}
  '';
in
pkgs.writeShellScriptBin "yolo" ''
  export YOLO_LLM_SANDBOX="${llm-sandbox}/bin/llm-sandbox"
  export YOLO_NIX_LD="${nix-ld}/bin/nix-ld"
  export YOLO_JQ="${jq}/bin/jq"
  export YOLO_COPILOT_DEFAULT_CONFIG="${copilotConfig}"
  export YOLO_COPILOT_BIN="${github-copilot-cli}/bin/copilot"
  export YOLO_COPILOT_MODEL=${lib.escapeShellArg copilotModel}
  export YOLO_COPILOT_REASONING_EFFORT=${lib.escapeShellArg copilotReasoningEffort}
  export YOLO_HW_NVIDIA_ENABLE=${if hwNvidiaEnable then "1" else "0"}
  export YOLO_HW_AMD_GPU_ENABLE=${if hwAmdGpuEnable then "1" else "0"}
  ${podmanExports}
  exec bash ${yoloScript} "$@"
''
