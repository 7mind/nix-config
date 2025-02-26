{ pkgs, lib, config, ... }:
{
  options = {
    smind.llm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.llm.enable {
    environment.systemPackages = with pkgs; [
      jan
      alpaca

      aichat
      gollama
      oterm
    ];

    services.ollama = {
      enable = true;
      package = pkgs.ollama-rocm;

      rocmOverrideGfx = "11.0.0";
      # rocmOverrideGfx = "10.3.0";

      acceleration = "rocm";
      port = 11434;

      loadModels = [
        "nomic-embed-text"

        "llama3.3:70b"

        "deepseek-r1:32b"
        # "deepseek-r1:70b"
        "r1-1776:72b" # uncensored (basic)

        "huihui_ai/qwen2.5-coder-abliterate:14b"
        "huihui_ai/qwen2.5-coder-abliterate:32b"

        #"qwen2.5:32b"
        "huihui_ai/qwen2.5-abliterate:32b" # uncensored (abliterated)

        #"qwen2.5:72b"
        "huihui_ai/qwen2.5-abliterate:72b" # uncensored (abliterated)

        "llava-llama3:8b"
        #"llama3.2-vision:11b"
        "Drews54/llama3.2-vision-abliterated:11b"

        #"phi4:14b"
        "huihui_ai/phi4-abliterated"
      ];

      environmentVariables = {
        # OLLAMA_SCHED_SPREAD = "true";
        # HSA_OVERRIDE_GFX_VERSION_0 = "11.0.0";
        # HSA_OVERRIDE_GFX_VERSION_1 = "10.3.0";
        ROCR_VISIBLE_DEVICES = "0";
      };
    };

    # services.tabby = {
    #   enable = true;
    #   acceleration = "rocm";
    # };

    networking.firewall = {
      allowedTCPPorts = [
        8188 # comfyui
        8189 # comfyui
      ];
    };

    services.open-webui = {
      enable = true;
      environment = {
        OLLAMA_API_BASE_URL = "http://127.0.0.1:11434";
        WEBUI_AUTH = "False";
      };
    };
  };

}
