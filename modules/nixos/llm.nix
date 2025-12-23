{ pkgs, lib, config, ... }:
{
  options = {
    smind.llm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable LLM tools (Ollama, aider, Claude Code)";
    };
  };

  config = lib.mkIf config.smind.llm.enable {
    environment.systemPackages = with pkgs; [
      #llama-cpp-rocm
      mistral-rs

      # terminal clients
      gollama
      oterm

      # repo ingestion - don't need
      # yek
      # gitingest # broken

      # jan
      # alpaca
    ];

    environment.variables = {
      OLLAMA_API_BASE = "http://127.0.0.1:11434";
    };


    services.ollama = {
      enable = true;
      package = pkgs.ollama-rocm;

      user = "ollama";
      group = "users";
      home = "/var/lib/ollama";
      host = "[::]";
      port = 11434;
      openFirewall = true;

      environmentVariables = {
        OLLAMA_DEBUG = "1";
        OLLAMA_NEW_ENGINE = "0";
        OLLAMA_CONTEXT_LENGTH = "16384";
        OLLAMA_FLASH_ATTENTION = "1";
        OLLAMA_SCHED_SPREAD = "0";
      };

      # ollama show <modelname> --modelfile > custom.modelfile
      # ollama create <yourmodelname> -f custom.modelfile
      # context size: PARAMETER num_ctx 8192

      loadModels = [
        "nomic-embed-text"
        "mxbai-embed-large"

        "mistral-small3.2:24b"
        "huihui_ai/phi4-abliterated:14b"
        "huihui_ai/qwen3-abliterated:32b"

        "devstral:24b-small-2505-q8_0"
        "devstral:24b-small-2505-fp16"

        "qwen2.5:32b-instruct-q8_0"

        "gpt-oss:20b"
      ];


    };

    services.open-webui = {
      # enable = true; # broken
      openFirewall = true;
      host = "0.0.0.0";
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

  };

}
