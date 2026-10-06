{
  pkgs,
  config,
  smind-hm,
  lib,
  extended_pkg,
  cfg-meta,
  xdg_associate,
  import_if_exists,
  import_if_exists_or,
  ...
}:

let
  host = config.smind.hm.globals;
  llamaSwapBaseUrl = "http://127.0.0.1:${toString host.llama-swap.port}/v1";
  llamaSwapModels = [
    { id = "qwen3.8-27b-q8"; name = "Qwen3.8 27B Q8 local"; }
    { id = "qwen3.8-27b-q8-abliterated"; name = "Qwen3.8 27B Q8 abliterated local"; }
  ];
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

  assertions = lib.optionals host.llama-swap.enable [
    {
      assertion = host.llama-swap.port != null;
      message = "The pavel-am5 Pi model provider requires a llama-swap port";
    }
    {
      assertion = builtins.all (m: host.llama-swap.models ? ${m.id}) llamaSwapModels;
      message = "Pi models must exist in services.llama-swap.settings.models: ${lib.concatMapStringsSep ", " (m: m.id) llamaSwapModels}";
    }
  ];

  home.file."${config.programs.pi.configDir}/models.json" = lib.mkIf host.llama-swap.enable {
    source =
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

          models = map (m: {
            inherit (m) id name;
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
          }) llamaSwapModels;
        };
      };
  };

  smind.hm.apps.prusa-3d-printing.enable = true;


  smind.hm.electron-wrappers = {
    enable = true;
    slack.enable = true;
    slack.netns = lib.mkIf (builtins.elem "vpn" host.net.namespaces) "vpn";
  };

  smind.hm.firefox.scrollMultiplier = 200;
}
