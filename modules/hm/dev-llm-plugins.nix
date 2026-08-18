{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.smind.hm.dev.llm;

  mkHarnessPluginOptions =
    optionName: pluginName:
    let
      pluginCfg = cfg.${optionName};
    in
    {
      enable = lib.mkEnableOption "the ${pluginName} plugin";
      claude.enable = lib.mkEnableOption "the ${pluginName} plugin for Claude Code" // {
        default = pluginCfg.enable;
      };
      codex.enable = lib.mkEnableOption "the ${pluginName} plugin for Codex" // {
        default = pluginCfg.enable;
      };
      pi.enable = lib.mkEnableOption "the ${pluginName} plugin for Pi" // {
        default = pluginCfg.enable;
      };
    };

  iHaveAdhdPlugin = pkgs.fetchFromGitHub {
    pname = "i-have-adhd";
    version = "0.2.0";
    owner = "ayghri";
    repo = "i-have-adhd";
    rev = "1fa9c7cc4b8a4e1e247388d213214bdc83ce8e67";
    hash = "sha256-qkMHSn5/dka10iMzk5A0AGgwkknQROH3Wp5qwwfvuyg=";
  };

  cavemanSkill = pkgs.fetchurl {
    name = "caveman";
    url = "https://raw.githubusercontent.com/JuliusBrussee/caveman/2c67abb9833689b48c7abba88afaa77c39a18657/skills/caveman/SKILL.md";
    hash = "sha256-2vnOxJbr0DmAnYI2+Z8X+htL6q34zk4tUy0NpR1wr84=";
  };

  claudeAlwaysEnabledMarker = "${config.programs.claude-code.configDir}/.i-have-adhd-always";
  piAlwaysEnabledMarker = "${config.programs.pi.configDir}/.i-have-adhd-always";
  claudeAlwaysEnabledYoloHook = {
    command = ''
      marker="''${CLAUDE_CONFIG_DIR:-${config.programs.claude-code.configDir}}/.i-have-adhd-always"
      [ -e "$marker" ] || : > "$marker"
    '';
  };
  piAlwaysEnabledYoloHook = {
    command = ''
      marker="''${PI_CODING_AGENT_DIR:-${config.programs.pi.configDir}}/.i-have-adhd-always"
      [ -e "$marker" ] || : > "$marker"
    '';
  };
in
{
  options.smind.hm.dev.llm = {
    iHaveAdhdPlugin = lib.recursiveUpdate (mkHarnessPluginOptions "iHaveAdhdPlugin" "i-have-adhd") {
      claude.alwaysEnabled = lib.mkEnableOption "always-on i-have-adhd mode for Claude Code" // {
        default = true;
      };
      pi.alwaysEnabled = lib.mkEnableOption "always-on i-have-adhd mode for Pi" // {
        default = true;
      };
    };
    cavemanPlugin = mkHarnessPluginOptions "cavemanPlugin" "Caveman";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf cfg.iHaveAdhdPlugin.claude.enable (
        lib.mkMerge [
          { programs.claude-code.plugins.i-have-adhd = iHaveAdhdPlugin; }
          (lib.mkIf cfg.iHaveAdhdPlugin.claude.alwaysEnabled {
            home.file."${claudeAlwaysEnabledMarker}".text = "";
            smind.hm.dev.llm.yolo.hooks.pre-start = {
              sandbox = [ claudeAlwaysEnabledYoloHook ];
              shell = [ claudeAlwaysEnabledYoloHook ];
            };
          })
        ]
      ))
      (lib.mkIf cfg.iHaveAdhdPlugin.codex.enable {
        programs.codex.plugins = [ iHaveAdhdPlugin ];
      })
      (lib.mkIf cfg.iHaveAdhdPlugin.pi.enable (
        lib.mkMerge [
          {
            programs.pi = {
              skills = {
                i-have-adhd = builtins.readFile "${iHaveAdhdPlugin}/skills/i-have-adhd/SKILL.md";
              };
              settings.extensions = [ "${iHaveAdhdPlugin}/extensions/i-have-adhd.ts" ];
            };
          }
          (lib.mkIf cfg.iHaveAdhdPlugin.pi.alwaysEnabled {
            home.file."${piAlwaysEnabledMarker}".text = "";
            smind.hm.dev.llm.yolo.hooks.pre-start = {
              sandbox = [ piAlwaysEnabledYoloHook ];
              shell = [ piAlwaysEnabledYoloHook ];
            };
          })
        ]
      ))

      (lib.mkIf cfg.cavemanPlugin.claude.enable {
        programs.claude-code.skills.caveman = builtins.readFile cavemanSkill;
      })
      (lib.mkIf cfg.cavemanPlugin.codex.enable {
        programs.codex.skills.caveman = builtins.readFile cavemanSkill;
      })
      (lib.mkIf cfg.cavemanPlugin.pi.enable {
        programs.pi.skills.caveman = builtins.readFile cavemanSkill;
      })
    ]
  );
}
