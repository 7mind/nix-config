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
      aichat
      gollama
      oterm

      jan
      alpaca
      tabby
    ];

    services.ollama = {
      enable = true;
      package = pkgs.ollama-rocm;

      user = "ollama";
      group = "users";
      home = "/var/lib/ollama";
      port = 11434;

      acceleration = "rocm";
      rocmOverrideGfx = "11.0.0";

      environmentVariables = {
        OLLAMA_NEW_ENGINE = "0";
        OLLAMA_CONTEXT_LENGTH = "16384";
        OLLAMA_FLASH_ATTENTION = "1";
        OLLAMA_SCHED_SPREAD = "1";
        HSA_OVERRIDE_GFX_VERSION_3 = "10.3.0";
        ROCR_VISIBLE_DEVICES = "0,1,2";
      };

      loadModels = [
        "nomic-embed-text"
        "mxbai-embed-large"

        "linux6200/bge-reranker-v2-m3"


        "huihui_ai/llama3.3-abliterated:70b"
        "huihui_ai/deepseek-r1-abliterated:32b"
        "huihui_ai/deepseek-r1-abliterated:70b"
        "huihui_ai/qwen2.5-coder-abliterate:14b"
        "huihui_ai/qwen2.5-coder-abliterate:32b"
        "huihui_ai/qwen2.5-abliterate:32b"
        "huihui_ai/qwen2.5-abliterate:72b"
        "huihui_ai/phi4-abliterated:14b"

        "llava-llama3:8b"
        "Drews54/llama3.2-vision-abliterated:11b"
        "jean-luc/big-tiger-gemma:27b-v1c-Q6_K"
      ];


    };

    services.open-webui = {
      enable = true;
      openFirewall = true;
      environment = {
        OLLAMA_API_BASE_URL = "http://0.0.0.0:11434";
        WEBUI_AUTH = "True";

        ANONYMIZED_TELEMETRY = "False";
        DO_NOT_TRACK = "True";
        SCARF_NO_ANALYTICS = "True";
      };
    };

    networking.firewall = {
      allowedTCPPorts = [
        8188 # comfyui
        8189 # comfyui
      ];
    };

    # services.tabby = {
    #   enable = true;
    #   acceleration = "rocm";
    #   # https://github.com/TabbyML/registry-tabby
    #   model = "Qwen2.5-Coder-14B";
    # };
  };

}
