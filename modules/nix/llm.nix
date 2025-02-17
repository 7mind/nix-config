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
      acceleration = "rocm";
      port = 11434;

      loadModels = [
        "llama3.3:70b"

        "nomic-embed-text"

        "deepseek-r1:70b"

        "qwen2.5:72b"
        "qwen2.5-coder:32b"
        "huihui_ai/qwen2.5-abliterate:72b" # uncensored
      ];

      environmentVariables = {
        OLLAMA_SCHED_SPREAD = "true";
        ROCR_VISIBLE_DEVICES = "0";
      };
    };

    # services.tabby = {
    #   enable = true;
    #   acceleration = "rocm";
    # };

    services.open-webui = {
      enable = true;
      environment = {
        OLLAMA_API_BASE_URL = "http://127.0.0.1:11434";
        WEBUI_AUTH = "False";
      };
    };
  };

}
