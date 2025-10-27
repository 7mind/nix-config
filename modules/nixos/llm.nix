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

      (writeShellScriptBin "yolo-claude" ''
        set -e
        firejail --noprofile \
          --whitelist="''${PWD}" \
          --whitelist="''${HOME}/.claude" \
          --whitelist="''${HOME}/.claude.json" \
          --whitelist="''${HOME}/.config/claude" \
          --whitelist="''${HOME}/.claude" \
          --whitelist="''${HOME}/.claude.json" \
          --whitelist="''${HOME}/.config/claude" \
          claude \
          --permission-mode bypassPermissions $*
      '')
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


            dataRoot = "./data";
            listen = false;
            listenAddress = {
              ipv4 = "0.0.0.0";
              ipv6 = "[::]";
            };
            protocol = {
              ipv4 = true;
              ipv6 = false;
            };
            dnsPreferIPv6 = false;
            browserLaunch = {
              enabled = true;
              browser = "default";
              hostname = "auto";
              port = -1;
              avoidLocalhost = false;
            };
            port = 8000;
            ssl = {
              enabled = false;
              certPath = "./certs/cert.pem";
              keyPath = "./certs/privkey.pem";
              keyPassphrase = "";
            };
            whitelistMode = true;
            enableForwardedWhitelist = true;
            whitelist = [
              "::1"
              "127.0.0.1"
            ];
            whitelistDockerHosts = true;
            basicAuthMode = false;
            basicAuthUser = {
              username = "user";
              password = "password";
            };
            enableCorsProxy = false;
            requestProxy = {
              enabled = false;
              url = "socks5://username:password@example.com:1080";
              bypass = [
                "localhost"
                "127.0.0.1"
              ];
            };
            enableUserAccounts = false;
            enableDiscreetLogin = false;
            perUserBasicAuth = false;
            sso = {
              autheliaAuth = false;
              authentikAuth = false;
            };
            hostWhitelist = {
              enabled = false;
              scan = true;
              hosts = [

              ];
            };
            sessionTimeout = -1;
            disableCsrfProtection = false;
            securityOverride = false;
            logging = {
              enableAccessLog = true;
              minLogLevel = 0;
            };
            rateLimiting = {
              preferRealIpHeader = false;
            };
            backups = {
              common = {
                numberOfBackups = 50;
              };
              chat = {
                enabled = true;
                checkIntegrity = true;
                maxTotalBackups = -1;
                throttleInterval = 10000;
              };
            };
            thumbnails = {
              enabled = true;
              format = "jpg";
              quality = 95;
              dimensions = {
                bg = [
                  160
                  90
                ];
                avatar = [
                  96
                  144
                ];
                persona = [
                  96
                  144
                ];
              };
            };
            performance = {
              lazyLoadCharacters = false;
              memoryCacheCapacity = "100mb";
              useDiskCache = true;
            };
            cacheBuster = {
              enabled = false;
              userAgentPattern = "";
            };
            allowKeysExposure = false;
            skipContentCheck = false;
            whitelistImportDomains = [
              "localhost"
              "cdn.discordapp.com"
              "files.catbox.moe"
              "raw.githubusercontent.com"
              "char-archive.evulid.cc"
            ];
            requestOverrides = [

            ];
            extensions = {
              enabled = true;
              autoUpdate = true;
              models = {
                autoDownload = true;
                classification = "Cohee/distilbert-base-uncased-go-emotions-onnx";
                captioning = "Xenova/vit-gpt2-image-captioning";
                embedding = "Cohee/jina-embeddings-v2-base-en";
                speechToText = "Xenova/whisper-small";
                textToSpeech = "Xenova/speecht5_tts";
              };
            };
            enableDownloadableTokenizers = true;
            promptPlaceholder = "[Start a new chat]";
            openai = {
              randomizeUserId = false;
              captionSystemPrompt = "";
            };
            deepl = {
              formality = "default";
            };
            mistral = {
              enablePrefix = false;
            };
            ollama = {
              keepAlive = -1;
              batchSize = -1;
            };
            claude = {
              enableSystemPromptCache = false;
              cachingAtDepth = -1;
              extendedTTL = false;
            };
            gemini = {
              apiVersion = "v1beta";
            };
            enableServerPlugins = false;
            enableServerPluginsAutoUpdate = true;


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
