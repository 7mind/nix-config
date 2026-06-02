# First-class home-manager module for the Pi coding agent
# (https://github.com/earendil-works/pi).
#
# Built from the shared lib/mk-agent-harness.nix factory (common surface:
# enable/package/configDir/settings/context/skills/enableMcpIntegration)
# plus Pi-specific extras below. Slots into dev-llm.nix identically to the
# upstream programs.{claude-code,codex,opencode} modules.
#
# Pi config layout (https://pi.dev/docs/latest):
#   ~/.pi/agent/settings.json   global settings (JSON)
#   ~/.pi/agent/AGENTS.md       concatenated agent instructions / memory
#   ~/.pi/agent/skills/<n>/SKILL.md   skills (progressive disclosure)
#   ~/.pi/agent/extensions/*.ts       auto-discovered TS extensions
#   settings.packages / settings.extensions   npm:/git: packages + local exts
#   PI_CODING_AGENT_DIR         overrides the ~/.pi/agent location
#
# MCP: Pi has no built-in MCP. The `pi-mcp-adapter` package reads
# ~/.config/mcp/mcp.json — which `programs.mcp` already writes — so
# enableMcpIntegration only needs to add the adapter to settings.packages;
# no native MCP file is generated.
let
  mkAgentHarness = import ../../lib/mk-agent-harness.nix;
in
{
  imports = [
    (mkAgentHarness {
      name = "pi";
      prettyName = "Pi";
      defaultConfigDir = ".pi/agent";
      configDirEnv = "PI_CODING_AGENT_DIR";
      formatType = "json";
      settingsFile = "settings.json";
      contextFile = "AGENTS.md";
      skillsSubdir = "skills";
      # Ledger (and other) command bundles provide keys like "plan/advance".
      # Materialise as prompts/plan:advance.md so Pi's prompt-template
      # discovery turns them into invocable /plan:advance slash commands
      # (matching the frontmatter description/argument-hint format).
      promptTemplatesSubdir = "prompts";
    })

    (
      { config, lib, ... }:
      let
        cfg = config.programs.pi;
      in
      {
        options.programs.pi = {
          extensionsDir = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = ''
              Directory of TypeScript extensions symlinked into
              {file}`extensions/` under {option}`programs.pi.configDir`.
              Each entry is either {file}`<name>.ts` or
              {file}`<name>/index.ts`.
            '';
            example = lib.literalExpression "./pi-extensions";
          };

          mcpAdapterPackage = lib.mkOption {
            type = lib.types.str;
            default = "npm:pi-mcp-adapter";
            description = ''
              Pi package spec for the MCP adapter, added to
              {option}`programs.pi.settings.packages` when
              {option}`programs.pi.enableMcpIntegration` is set. Pin a
              version with e.g. {command}`"npm:pi-mcp-adapter@1.2.3"`.
            '';
          };

          appendSystemPrompt = lib.mkOption {
            type = lib.types.either lib.types.lines lib.types.path;
            default = "";
            description = ''
              Content appended verbatim to Pi's built-in system prompt,
              written to {file}`APPEND_SYSTEM.md` in
              {option}`programs.pi.configDir` (Pi auto-discovers it there).
              Unlike {option}`programs.pi.context` (AGENTS.md, loaded as
              {var}`<project_context>`), this lands *inside* the system
              prompt and therefore carries higher authority. Use it for
              global, repo-agnostic behavioural rules; keep project-specific
              facts in {option}`programs.pi.context`. Either inline content
              or a path. Empty string disables the file.
            '';
          };
        };

        config = lib.mkIf cfg.enable (lib.mkMerge [
          # Pi's adapter reads the shared ~/.config/mcp/mcp.json registry
          # (written by programs.mcp); we only need to load the adapter.
          (lib.mkIf cfg.enableMcpIntegration {
            programs.pi.settings.packages = [ cfg.mcpAdapterPackage ];
          })
          (lib.mkIf (cfg.extensionsDir != null) {
            home.file."${cfg.configDir}/extensions" = {
              source = cfg.extensionsDir;
              recursive = true;
            };
          })
          (lib.mkIf (cfg.appendSystemPrompt != "") {
            home.file."${cfg.configDir}/APPEND_SYSTEM.md" =
              if lib.isPath cfg.appendSystemPrompt then
                { source = cfg.appendSystemPrompt; }
              else
                { text = cfg.appendSystemPrompt; };
          })
        ]);
      }
    )
  ];
}
