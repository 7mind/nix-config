{
  pkgs,
  config,
  smind-hm,
  lib,
  extended_pkg,
  cfg-meta,
  xdg_associate,
  outerConfig,
  import_if_exists,
  import_if_exists_or,
  ...
}:

let
  qwenModelId = "qwen3.8-27b-q8";
  llamaSwapBaseUrl = "http://127.0.0.1:${toString outerConfig.services.llama-swap.port}/v1";
in
{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic-linux.nix"
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-electronics.nix"
  ];

  home.packages = with pkgs; [
    kicad
  ];

  assertions = [
    {
      assertion = outerConfig.services.llama-swap.enable;
      message = "The pavel-am5 Pi model provider requires services.llama-swap.enable";
    }
    {
      assertion = builtins.hasAttr qwenModelId outerConfig.services.llama-swap.settings.models;
      message = "The Pi model ${qwenModelId} must exist in services.llama-swap.settings.models";
    }
  ];

  home.file."${config.programs.pi.configDir}/models.json".source =
    (pkgs.formats.json { }).generate "pi-models.json" {
      providers.llama-swap = {
        baseUrl = llamaSwapBaseUrl;
        api = "openai-completions";
        apiKey = "local";

        compat = {
          supportsStore = false;
          supportsDeveloperRole = false;
          supportsReasoningEffort = true;
          supportsUsageInStreaming = true;
          supportsStrictMode = false;
          maxTokensField = "max_tokens";
        };

        models = [
          {
            id = qwenModelId;
            name = "Qwen3.8 27B Q8 local";
            reasoning = true;
            input = [ "text" ];
            contextWindow = 262144;
            maxTokens = 32768;

            thinkingLevelMap = {
              off = "none";
              minimal = null;
              low = null;
              medium = null;
              high = null;
              xhigh = "xhigh";
              max = null;
            };

            samplingParams = {
              temperature = 1.0;
              top_p = 0.95;
              top_k = 20;
              min_p = 0.0;
              presence_penalty = 0.0;
              repeat_penalty = 1.0;
            };
          }
        ];
      };
    };

  smind.hm.apps.prusa-3d-printing.enable = true;


  smind.hm.electron-wrappers = {
    enable = true;
    slack.enable = true;
    slack.netns = "vpn";
  };

  smind.hm.firefox.scrollMultiplier = 200;
}
