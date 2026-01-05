{ pkgs, lib, config, ... }:
{
  options = {
    smind.llm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable LLM tools (Ollama, aider, Claude Code)";
    };

    smind.llm.ollama.package = lib.mkOption {
      type = lib.types.package;
      # default = pkgs.ollama-rocm;
      default = pkgs.ollama-vulkan;
      description = "Ollama package to use (ollama-rocm, ollama-vulkan, ollama-cuda, ollama-cpu)";
    };
  };

  config = lib.mkIf config.smind.llm.enable {
    environment.systemPackages = with pkgs; [
      #llama-cpp-rocm
      mistral-rs

      # terminal clients
      gollama
      #oterm

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
      package = config.smind.llm.ollama.package;

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

    # Custom Ollama models with specific parameters
    systemd.services.ollama-custom-models = {
      description = "Create custom Ollama models with specific parameters";
      after = [ "ollama.service" ];
      wants = [ "ollama.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "ollama";
        Group = "users";
      };
      path = [ config.services.ollama.package pkgs.coreutils ];
      script = ''
        # Wait for Ollama to be ready
        for i in $(seq 1 30); do
          ollama list && break
          sleep 2
        done

        MODELFILE=$(mktemp)
        trap "rm -f $MODELFILE" EXIT

        # Create devstral:24b-small-2505-128k with 128k context
        if ! ollama list | grep -q "devstral:24b-small-2505-128k"; then
          echo "Creating devstral:24b-small-2505-128k..."
          cat > "$MODELFILE" << 'EOF'
FROM devstral:24b-small-2505-q8_0
PARAMETER num_ctx 131072
EOF
          ollama create devstral:24b-small-2505-128k -f "$MODELFILE"
        fi
      '';
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
