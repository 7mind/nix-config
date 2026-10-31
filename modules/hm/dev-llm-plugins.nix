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
    version = "0.4.1";
    owner = "ayghri";
    repo = "i-have-adhd";
    rev = "1ecea1993b7fce257ffbd686c070948b5e07eda6";
    hash = "sha256-GTqrnZxQvzo/ogAuUrffkOaMK1BYm/4rAZsnfmDt7DU=";
  };

  # Codex 0.165 approves the reviewed bundle as well as its hook declaration.
  iHaveAdhdContentHash = "sha256:01ff4c97c9d3862b76fa2a141fc868bd615d22dec5665e0895d579ee42b9a612";

  cavemanSkills = lib.mapAttrs (name: hash: builtins.readFile (pkgs.fetchurl {
    inherit name hash;
    url = "https://raw.githubusercontent.com/JuliusBrussee/caveman/d262ab3882952a59312ff3537cd86d894523c5ab/skills/${name}/SKILL.md";
  })) {
    caveman = "sha256-QV1DUY8rGpSYwVpEXUZXEXsSnuXoGxlFTONIQ5zGZys=";
    ultracave = "sha256-qNpbCzUBuFPhuY8q4J/o3JwO30gbHT+pUp+FVwEcHvg=";
    megacave = "sha256-E5EFKWwGhsHuJGEMrKHbKTq4QWK+sNlKp6mtfLwzUr8=";
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
      (lib.mkIf cfg.iHaveAdhdPlugin.codex.enable (let
        pluginManifest = builtins.fromJSON (builtins.readFile "${iHaveAdhdPlugin}/.codex-plugin/plugin.json");
        pluginKey = "${pluginManifest.name}@home-manager";
        pluginHooks = builtins.fromJSON (builtins.readFile "${iHaveAdhdPlugin}/hooks/hooks.json");
        eventLabels = {
          PreModelRequest = "pre_model_request";
          PostModelRequest = "post_model_request";
          PreToolUse = "pre_tool_use";
          PermissionRequest = "permission_request";
          PostToolUse = "post_tool_use";
          PreCompact = "pre_compact";
          PostCompact = "post_compact";
          SessionStart = "session_start";
          SessionEnd = "session_end";
          UserPromptSubmit = "user_prompt_submit";
          SubagentStart = "subagent_start";
          SubagentStop = "subagent_stop";
          Stop = "stop";
          Interrupt = "interrupt";
        };
        matcherKept = label: !(lib.elem label [ "pre_model_request" "post_model_request" "user_prompt_submit" "stop" "interrupt" ]);
        contextLimitKept = label: lib.elem label [ "pre_tool_use" "post_tool_use" "session_start" "user_prompt_submit" "subagent_start" ];
        normalizeTimeout = label: timeout:
          if label == "session_end" || label == "interrupt" then
            let t = if timeout == null then 1 else timeout; in if t < 1 then 1 else if t > 3 then 3 else t
          else
            let t = if timeout == null then 600 else timeout; in if t < 1 then 1 else t;
        commandIdentity = label: handler:
          ({
            type = "command";
            command = handler.command;
            timeout = normalizeTimeout label (handler.timeout or null);
            async = handler.async or false;
          }
          // lib.optionalAttrs (handler ? statusMessage && handler.statusMessage != null) {
            inherit (handler) statusMessage;
          }
          // lib.optionalAttrs
            (handler ? additionalContextLimit && handler.additionalContextLimit != null && handler.additionalContextLimit != 2500 && contextLimitKept label) {
            inherit (handler) additionalContextLimit;
          });
        hookTrustEntries = lib.concatLists (lib.mapAttrsToList
          (event: groups:
            let label = eventLabels.${event}; in lib.concatLists (lib.imap0
              (gi: group:
                lib.map (pair: {
                  name = "${pluginKey}:hooks/hooks.json:${label}:${toString gi}:${toString pair.hi}";
                  value.trusted_content_hash = iHaveAdhdContentHash;
                  value.trusted_hash =
                    "sha256:${builtins.hashString "sha256" (builtins.toJSON ({
                      event_name = label;
                      hooks = [ (commandIdentity label pair.handler) ];
                    }
                    // lib.optionalAttrs
                      (matcherKept label && group ? matcher && group.matcher != null)
                      { inherit (group) matcher; }))}";
                })
                (lib.filter (pair: (pair.handler.type or "command") == "command")
                  (lib.imap0 (hi: handler: { inherit hi handler; }) group.hooks)))
            groups))
          (lib.filterAttrs (event: groups: eventLabels ? ${event} && groups != [ ]) pluginHooks.hooks));
      in {
        programs.codex.plugins = [ iHaveAdhdPlugin ];
        programs.codex.settings.hooks.state = lib.listToAttrs hookTrustEntries;
      }))
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
        programs.claude-code.skills = cavemanSkills;
      })
      (lib.mkIf cfg.cavemanPlugin.codex.enable {
        programs.codex.skills = cavemanSkills;
      })
      (lib.mkIf cfg.cavemanPlugin.pi.enable {
        programs.pi.skills = cavemanSkills;
      })
    ]
  );
}
