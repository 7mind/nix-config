# Reusable home-manager module factory for AI coding-agent harnesses.
#
# Captures the option surface shared by every harness we manage
# (claude-code, codex, opencode, pi, ...): a config directory, a
# format-generated settings file, a concatenated memory/context file, a
# `skills/<name>/SKILL.md` tree, and an `enableMcpIntegration` toggle that
# feeds from the shared `programs.mcp` registry.
#
# It deliberately does NOT subsume the upstream nix-community/home-manager
# modules (claude-code/codex/...), which live read-only in the
# home-manager input. It is the base for first-party harness modules such
# as `programs.pi`. Harness-specific surface (plugin wrappers, extension
# directories, the concrete effect of `enableMcpIntegration`) is layered
# on top by the consuming module via `imports`.
#
# Destined for 7mind-nix (smind); developed here because smind is a
# github-pinned input with no local checkout. Written as a standalone
# function with no nix-config-specific dependencies so it lifts verbatim.
#
# Usage:
#   imports = [ (import ./mk-agent-harness.nix { name = "pi"; ... }) ];
spec@{
  # Program attribute name and on-PATH binary name (e.g. "pi").
  name,
  # Human-readable name for option descriptions (e.g. "Pi").
  prettyName,
  # Config directory relative to $HOME (e.g. ".pi/agent").
  defaultConfigDir,
  # Environment variable the CLI reads to locate its config dir, exported
  # only when `configDir` differs from the default. null = don't export.
  configDirEnv ? null,
  # Settings file format: "json" | "toml" | "yaml".
  formatType ? "json",
  # Settings filename within the config dir (e.g. "settings.json").
  settingsFile,
  # Optional JSON-schema URL injected as "$schema" into settings.
  settingsSchema ? null,
  # Memory/context filename within the config dir (e.g. "AGENTS.md").
  # null disables the `context` option's effect.
  contextFile ? null,
  # Subdirectory holding skills (e.g. "skills"). null disables `skills`.
  skillsSubdir ? null,
  # Subdirectory holding prompt templates / slash commands (e.g. "prompts" for Pi).
  # null disables. Keys like "plan/advance" are materialized with "/" → ":"
  # in the filename (plan:advance.md) so that discovery produces usable
  # namespaced template names matching other harnesses.
  promptTemplatesSubdir ? null,
}:
{ config, lib, pkgs, ... }:
let
  cfg = config.programs.${name};

  fmt =
    {
      json = pkgs.formats.json { };
      toml = pkgs.formats.toml { };
      yaml = pkgs.formats.yaml { };
    }
    .${formatType};

  upstreamConfigDir = "${config.home.homeDirectory}/${defaultConfigDir}";

  isStorePathString = c: builtins.isString c && lib.hasPrefix "${builtins.storeDir}/" c;
  isPathLikeContent = c: lib.isPath c || isStorePathString c;

  mkSkillEntry =
    skillName: content:
    if isPathLikeContent content && lib.pathIsDirectory content then
      lib.nameValuePair "${cfg.configDir}/${skillsSubdir}/${skillName}" {
        source = content;
        recursive = true;
      }
    else
      lib.nameValuePair "${cfg.configDir}/${skillsSubdir}/${skillName}/SKILL.md" (
        if isPathLikeContent content then { source = content; } else { text = content; }
      );

  mkPromptTemplateEntry =
    tmplKey: content:
    let
      # Sanitize key for filename while preserving namespace intent.
      # "plan/advance" → "plan:advance.md" → template name "plan:advance"
      # (matches Claude /plan:advance and ledger command keys).
      fileStem = lib.replaceStrings [ "/" ] [ ":" ] tmplKey;
      path = "${cfg.configDir}/${promptTemplatesSubdir}/${fileStem}.md";
    in
    lib.nameValuePair path (
      if isPathLikeContent content then { source = content; } else { text = content; }
    );
in
{
  options.programs.${name} = {
    enable = lib.mkEnableOption "${prettyName}, an AI coding-agent harness";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        The ${prettyName} package to install. null installs no binary but
        still manages the configuration files (useful when the binary is
        provided out-of-band).
      '';
    };

    finalPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      readOnly = true;
      internal = true;
      default = cfg.package;
      description = "Resulting ${prettyName} package after any wrapping.";
    };

    enableMcpIntegration = lib.mkEnableOption ''
      wiring the shared {option}`programs.mcp.servers` registry into
      ${prettyName}. The concrete mechanism is harness-specific'';

    configDir = lib.mkOption {
      type = lib.types.str;
      default = upstreamConfigDir;
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/${defaultConfigDir}"'';
      description = "Directory holding ${prettyName}'s configuration files.";
    };

    settings = lib.mkOption {
      inherit (fmt) type;
      default = { };
      description = "Settings written to {file}`${settingsFile}` in {option}`programs.${name}.configDir`.";
    };

    context = lib.mkOption {
      type = lib.types.either lib.types.lines lib.types.path;
      default = "";
      description =
        if contextFile == null then
          "Unused for ${prettyName}."
        else
          "Global context/memory written to {file}`${contextFile}` in {option}`programs.${name}.configDir`. Either inline content or a path.";
    };

    skills = lib.mkOption {
      type = lib.types.either (lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.lines
          lib.types.path
          lib.types.str
        ]
      )) lib.types.path;
      default = { };
      description =
        if skillsSubdir == null then
          "Unused for ${prettyName}."
        else
          ''
            Skills for ${prettyName}. Either an attrset (name -> inline
            SKILL.md content, a file path, or a directory path) materialised
            under {file}`${skillsSubdir}/`, or a directory path symlinked
            wholesale into {file}`${skillsSubdir}/`.
          '';
    };

    promptTemplates = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.lines
          lib.types.path
          lib.types.str
        ]
      );
      default = { };
      description =
        if promptTemplatesSubdir == null then
          "Unused for ${prettyName}."
        else
          ''
            Prompt templates (slash-command bodies) for ${prettyName}.
            Keys are "<ns>/<name>" (e.g. "plan/advance"). Materialised as
            .md files under {file}`${promptTemplatesSubdir}/` using a
            namespaced stem ("plan:advance.md"). Matches the shape produced
            by asset bundles (ledger etc.).
          '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(isPathLikeContent cfg.skills) || lib.pathIsDirectory cfg.skills;
        message = "`programs.${name}.skills` must be a directory when set to a path";
      }
    ];

    home = {
      packages = lib.mkIf (cfg.finalPackage != null) [ cfg.finalPackage ];

      sessionVariables = lib.mkIf (configDirEnv != null && cfg.configDir != upstreamConfigDir) {
        ${configDirEnv} = cfg.configDir;
      };

      file = lib.mkMerge [
        (lib.mkIf (cfg.settings != { }) {
          "${cfg.configDir}/${settingsFile}".source = fmt.generate "${name}-${settingsFile}" (
            cfg.settings // lib.optionalAttrs (settingsSchema != null) { "$schema" = settingsSchema; }
          );
        })
        (lib.optionalAttrs (contextFile != null) (
          if lib.isPath cfg.context then
            { "${cfg.configDir}/${contextFile}".source = cfg.context; }
          else
            lib.mkIf (cfg.context != "") { "${cfg.configDir}/${contextFile}".text = cfg.context; }
        ))
        (lib.optionalAttrs (skillsSubdir != null) (
          lib.mkMerge [
            (lib.mkIf (isPathLikeContent cfg.skills) {
              "${cfg.configDir}/${skillsSubdir}" = {
                source = cfg.skills;
                recursive = true;
              };
            })
            (lib.optionalAttrs (builtins.isAttrs cfg.skills) (lib.mapAttrs' mkSkillEntry cfg.skills))
          ]
        ))
        (lib.optionalAttrs (promptTemplatesSubdir != null) (
          lib.mapAttrs' mkPromptTemplateEntry cfg.promptTemplates
        ))
      ];
    };
  };
}
