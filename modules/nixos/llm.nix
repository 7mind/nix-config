{ pkgs, lib, config, ... }:
let
  ollamaCfg = config.smind.llm.ollama;
in
{
  options = {
    smind.llm.enable = lib.mkEnableOption "LLM tools (Ollama, aider, Claude Code)";

    smind.llm.ollama.package = lib.mkOption {
      type = lib.types.package;
      # default = pkgs.ollama-rocm;
      default = pkgs.ollama-rocm;
      description = "Ollama package to use (ollama-rocm, ollama-vulkan, ollama-cuda, ollama-cpu)";
    };

    smind.llm.ollama.customContextLength = lib.mkOption {
      type = lib.types.int;
      default = 131072;
      description = "Default context length for custom Ollama models (default 128k)";
    };

    smind.llm.ollama.customModels = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule ({ config, ... }: {
        options = {
          baseName = lib.mkOption {
            type = lib.types.str;
            description = "Base model name used to create the custom Ollama model";
          };
          contextLength = lib.mkOption {
            type = lib.types.int;
            default = ollamaCfg.customContextLength;
            description = "Context length for this custom model";
          };
          name = lib.mkOption {
            type = lib.types.str;
            default = "${config.baseName}-custom";
            description = "Custom model name";
          };
        };
      }));
      default = [
        { baseName = "huihui_ai/qwen3.5-abliterated:35b"; }
        { baseName = "gemma4:e4b"; }
      ];
      description = "List of custom Ollama models to create with specific parameters";
    };
  };

  config = lib.mkIf config.smind.llm.enable {
    environment.systemPackages = with pkgs; [
      stable-diffusion-cpp-rocm

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

        "huihui_ai/glm-4.7-flash-abliterated:q8_0"
      ] ++ (map (m: m.baseName) ollamaCfg.customModels) ++ [

        "lfm2:24b-q8_0"

        "mistral-small3.2:24b"
        "devstral-small-2:24b-instruct-2512-q8_0"
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

                ${lib.concatMapStringsSep "\n" (model: ''
                # Create custom model: ${model.name}
                if ! ollama list | grep -Fq "${model.name}"; then
                  echo "Creating ${model.name} from ${model.baseName} with context ${toString model.contextLength}..."
                  cat > "$MODELFILE" << EOF
        FROM ${model.baseName}
        PARAMETER num_ctx ${toString model.contextLength}
        EOF
                  ollama create ${model.name} -f "$MODELFILE"
                fi
                '') ollamaCfg.customModels}
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
