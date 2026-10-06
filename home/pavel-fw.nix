{
  pkgs,
  config,
  smind-hm,
  lib,
  cfg-meta,
  import_if_exists_or,
  ...
}:

let
  host = config.smind.hm.globals;
  llamaSwapBaseUrl = "http://127.0.0.1:${toString host.llama-swap.port}/v1";
  llamaSwapModels = [
    { id = "qwen3.8-27b-q4"; name = "Qwen3.8 27B Q4 local"; }
    { id = "qwen3.8-27b-q4-abliterated"; name = "Qwen3.8 27B Q4 abliterated local"; }
  ];
in
{
  imports = smind-hm.imports ++ [
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic.nix"
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-generic-linux.nix"
    "${cfg-meta.paths.users}/pavel/hm/home-pavel-electronics.nix"
  ];

  assertions = lib.optionals host.llama-swap.enable [
    {
      assertion = host.llama-swap.port != null;
      message = "The pavel-fw Pi model provider requires a llama-swap port";
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
            contextWindow = 32768;
            maxTokens = 8192;

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

  services.wluma = {
    enable = false;
    settings = {
      als.iio = {
        path = "/sys/bus/iio/devices";
        thresholds = {
          "0" = "0";
          "5" = "5";
          "10" = "10";
          "20" = "20";
          "30" = "30";
          "50" = "50";
          "80" = "80";
          "250" = "250";
          "500" = "500";
        };
      };
      output.backlight = [
        {
          name = "eDP-1";
          path = "/sys/class/backlight/nvidia_wmi_ec_backlight";
          capturer = "none";
        }
      ];
    };
  };

  home.packages = with pkgs; [
    wineWow64Packages.stable # Wine (32+64-bit) — provides the `wine` binary
    winetricks
    umu-launcher # run Proton as a standalone Wine outside Steam
    protontricks # manage Proton prefixes (winetricks for Proton)
    protonup-qt # GUI to install/manage Proton-GE versions
  ];

  smind.hm = {
    vscodium.fontSize = 14;
    ghostty.fontSize = 11;

    desktop.cosmic.minimal-keybindings = true;

    apps.prusa-3d-printing.enable = true;

    # Resource-limited Electron apps
    electron-wrappers = {
      enable = true;
      slack.enable = true;
      slack.netns = lib.mkIf (builtins.elem "vpn" host.net.namespaces) "vpn";
      element.enable = true;
    };

  };
}
