{ pkgs, lib, ... }:

# llama.cpp + llama-swap on the RTX 5070 Laptop (8 GiB) + 890M overflow.
# 27B Q4 does not fit in dGPU VRAM; --fit keeps a 1 GiB margin per device
# and spills the rest to the 890M (Vulkan) instead of CPU.
#
# Vulkan is pinned to radv so Vulkan0 cannot become the 5070 (which is
# already CUDA0). Context is 32k, not the 262k used on am5/vm. Listen on
# localhost — this is a laptop.
let
  llamaCpp = (pkgs.llama-cpp.override {
    cudaSupport = true;
    vulkanSupport = true;
  }).overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ../pavel-am5/llama-cpp-json-schema-regex-shorthand.patch ];
  });
  llamaServer = lib.getExe' llamaCpp "llama-server";
  llamaSwap = pkgs.llama-swap.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ../pavel-am5/llama-swap-ttl-from-ready.patch ];
  });
  qwenModelId = "qwen3.8-27b-q4";
  qwenAbliteratedModelId = "qwen3.8-27b-q4-abliterated";
in
{
  environment.systemPackages = [ llamaCpp ];

  services.ollama.enable = lib.mkForce false;
  services.ollama.loadModels = lib.mkForce [ ];

  services.llama-swap = {
    enable = true;
    package = llamaSwap;
    listenAddress = "127.0.0.1";
    port = 11435;
    openFirewall = false;

    settings =
      let
        proxy = "http://127.0.0.1:\${PORT}";
        mkCmd = hfArgs:
          lib.escapeShellArgs (
            [
              llamaServer
              "--host"
              "127.0.0.1"
              "--port"
              "\${PORT}"
            ] ++ hfArgs ++ [
              "--no-mmproj"
              "-dev"
              "CUDA0,Vulkan0"
              # Unset -ngl so --fit can fill the 5070 then the 890M.
              "-fit"
              "on"
              "-fitt"
              "1024"
              "-fa"
              "on"
              "-ctk"
              "q8_0"
              "-ctv"
              "q8_0"
              "--spec-type"
              "draft-mtp"
              "--spec-draft-n-max"
              "3"
              "-ctkd"
              "q8_0"
              "-ctvd"
              "q8_0"
              "--threads"
              "12"
              "-c"
              "32768"
              "-np"
              "1"
            ]
          );
      in
      {
        healthCheckTimeout = 1800;
        globalTTL = 900;

        models.${qwenModelId} = {
          cmd = mkCmd [ "-hf" "bartowski/Qwen3.8-27B-GGUF:Q4_K_M" ];
          inherit proxy;
        };
        # huihui main ladder is Q4_K, not Q4_K_M. --hf-file so `:Q4_K`
        # cannot also match Q4_K_L.
        models.${qwenAbliteratedModelId} = {
          cmd = mkCmd [
            "-hf"
            "huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF"
            "--hf-file"
            "Huihui-Qwen3.8-27B-abliterated-Q4_K.gguf"
          ];
          inherit proxy;
        };
      };
  };

  systemd.services = {
    ollama-custom-models.enable = false;
    llama-swap = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        CUDA_VISIBLE_DEVICES = "0";
        # Session vulkaninfo listed 890M as device 0, but a headless
        # unit can enumerate NVIDIA first. Only load radv.
        VK_DRIVER_FILES = "/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json";
        VK_ICD_FILENAMES = "/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json";
      };
      serviceConfig = {
        SupplementaryGroups = [ "render" "video" ];
        MemoryDenyWriteExecute = lib.mkForce false;
        PrivateUsers = lib.mkForce false;
      };
    };
  };
}
