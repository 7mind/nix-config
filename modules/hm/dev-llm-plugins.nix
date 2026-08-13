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
    name = "i-have-adhd";
    owner = "ayghri";
    repo = "i-have-adhd";
    rev = "2ed064090711586e0c97a2fbbf15465fe8f1808b";
    hash = "sha256-/h4HxkUbtRGoqgyFvjJrd++XmOd1KSVku5dR2/f9b/s=";
  };

  cavemanSource = pkgs.fetchFromGitHub {
    name = "caveman";
    owner = "JuliusBrussee";
    repo = "caveman";
    rev = "2c67abb9833689b48c7abba88afaa77c39a18657";
    hash = "sha256-9G7m2U5EezqKozO03r07nSEBOGS9tO2fjklQVohdqO0=";
  };

  cavemanCodexPlugin = pkgs.runCommand "caveman" { } ''
    cp -r ${cavemanSource}/plugins/caveman "$out"
  '';

  claudeAlwaysEnabledMarker = "${config.programs.claude-code.configDir}/.i-have-adhd-always";
  piAlwaysEnabledMarker = "${config.programs.pi.configDir}/.i-have-adhd-always";
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
          { programs.claude-code.plugins = [ iHaveAdhdPlugin ]; }
          (lib.mkIf cfg.iHaveAdhdPlugin.claude.alwaysEnabled {
            home.file."${claudeAlwaysEnabledMarker}".text = "";
            smind.hm.dev.llm.yolo.extraReadOnlyPaths = [ claudeAlwaysEnabledMarker ];
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
            smind.hm.dev.llm.yolo.extraReadOnlyPaths = [ piAlwaysEnabledMarker ];
          })
        ]
      ))

      (lib.mkIf cfg.cavemanPlugin.claude.enable {
        programs.claude-code.plugins = [ cavemanSource ];
      })
      (lib.mkIf cfg.cavemanPlugin.codex.enable {
        programs.codex.plugins = [ cavemanCodexPlugin ];
      })
      (lib.mkIf cfg.cavemanPlugin.pi.enable {
        programs.pi.skills.caveman = builtins.readFile "${cavemanSource}/plugins/caveman/skills/caveman/SKILL.md";
      })
    ]
  );
}
