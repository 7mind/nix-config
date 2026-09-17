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
    version = "0.3.0";
    owner = "ayghri";
    repo = "i-have-adhd";
    rev = "b15d0be58f55b33972ba3e39709e0e5208ef30cb";
    hash = "sha256-wnD5crIal23Vtk6GReG2vCkjDuhrpmhWXvrNUq5mZfE=";
  };

  cavemanSkill = pkgs.fetchurl {
    name = "caveman";
    url = "https://raw.githubusercontent.com/JuliusBrussee/caveman/880114a42067d045b91dffe6a553f6ab2cc399ad/skills/caveman/SKILL.md";
    hash = "sha256-C/CaCpoBfQBKgdS2k+Wi2DDhooIwpYhd93Ph7ZwFccw=";
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
