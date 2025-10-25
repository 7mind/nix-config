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
      # tabby

      # agentic coding
      aichat
      aider-chat
      # opencode
      goose-cli
      claude-code
      codex
    ];


    environment.variables = {
      OLLAMA_API_BASE = "http://127.0.0.1:11434";
      AIDER_DARK_MODE = "true";
    };

    services.sillytavern = {
      enable = true;
      port = 8045;
      whitelist = false;
      configFile =
        let
          config = ((pkgs.formats.yaml { }).generate "config.yaml" {
            api = {
              ollama = {
                enabled = true;
                api_url = "http://127.0.0.1:11434/v1";
                api_key = "";
                default_model = "huihui_ai/phi4-abliterated:14b";
                prompt_template = "alpaca";
                max_context_length = 32768;
                temperature = 0.7;
                top_p = 0.9;
                top_k = 40;
              };
            };
          });
        in
        "${config}";
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

      acceleration = "rocm";
      rocmOverrideGfx = "11.0.0";

      environmentVariables = {
        OLLAMA_DEBUG = "1";
        OLLAMA_NEW_ENGINE = "0";
        OLLAMA_CONTEXT_LENGTH = "16384";
        OLLAMA_FLASH_ATTENTION = "1";
        OLLAMA_SCHED_SPREAD = "0";
        HSA_OVERRIDE_GFX_VERSION_3 = "10.3.0";
        ROCR_VISIBLE_DEVICES = "0,1,2";
      };

      # ollama show <modelname> --modelfile > custom.modelfile
      # ollama create <yourmodelname> -f custom.modelfile
      # context size: PARAMETER num_ctx 8192

      loadModels = [
        "nomic-embed-text"
        "mxbai-embed-large"

        "devstral:24b-small-2505-q8_0"
        "devstral:24b-small-2505-fp16"

        "qwen2.5:32b-instruct-q8_0"

        "gpt-oss:20b"

        # "qwen3:32b"

        # "huihui_ai/llama3.3-abliterated:70b"
        # "huihui_ai/deepseek-r1-abliterated:32b"
        # "huihui_ai/deepseek-r1-abliterated:70b"
        # "huihui_ai/qwen2.5-abliterate:32b"
        # "huihui_ai/qwen2.5-abliterate:72b"
        "huihui_ai/phi4-abliterated:14b"
        # "huihui_ai/qwen2.5-coder-abliterate:14b"
        # "huihui_ai/qwen2.5-coder-abliterate:32b"
        # "llava-llama3:8b"
        # "Drews54/llama3.2-vision-abliterated:11b"
        # "jean-luc/big-tiger-gemma:27b-v1c-Q6_K"
      ];


    };

    services.open-webui = {
      enable = true;
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

    # services.tabby-extended = {
    #   enable = true;
    #   acceleration = "rocm";

    #   # https://github.com/TabbyML/registry-tabby
    #   # model = "Qwen2.5-Coder-14B";

    #   # TABBY_WEBSERVER_JWT_TOKEN_SECRET

    #   settings = {
    #     model.chat.http = {
    #       kind = "openai/chat";
    #       model_name = "huihui_ai/deepseek-r1-abliterated:32b";
    #       api_endpoint = "http://localhost:11434/v1"; # yes, it's different for chat model
    #     };
    #     model.completion.http = {
    #       kind = "ollama/completion";
    #       model_name = "huihui_ai/qwen2.5-coder-abliterate:14b";
    #       api_endpoint = "http://localhost:11434";
    #       prompt_template = "<|fim_prefix|>{prefix}<|fim_suffix|>{suffix}<|fim_middle|>";
    #     };
    #     model.embedding.http = {
    #       kind = "ollama/embedding";
    #       model_name = "mxbai-embed-large";
    #       api_endpoint = "http://localhost:11434";
    #     };
    #   };
    # };


    # systemd.services.tabby = {
    #   unitConfig = {
    #     Wants = [ "ollama.service" ];
    #     After = [ "ollama.service" ];
    #   };
    # };

  };

}
