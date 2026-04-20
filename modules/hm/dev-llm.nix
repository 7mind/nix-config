{
  config,
  lib,
  pkgs,
  cfg-meta,
  outerConfig,
  inputs,
  ...
}:
let
  jsonFormat = pkgs.formats.json { };
  tomlFormat = pkgs.formats.toml { };

  codexPluginCc = pkgs.fetchFromGitHub {
    owner = "openai";
    repo = "codex-plugin-cc";
    rev = "6a5c2ba53b734f3cdd8daacbd49f68f3e6c8c167";
    hash = "sha256-4kqtfdHlcg3YXWX1og9b5JuLgnB/3Nj5dFMe4Ryt7No=";
  };
  rootlessPodmanEnabled =
    cfg-meta.isLinux && (outerConfig.smind.containers.docker.rootless.enable or false);
  rootlessPodmanSocketPathValue = outerConfig.smind.containers.docker.rootless.llmSocketPath or null;
  rootlessPodmanSocketUriValue = outerConfig.smind.containers.docker.rootless.llmSocketUri or null;
  rootlessPodmanSocketPath =
    if !rootlessPodmanEnabled then
      null
    else if rootlessPodmanSocketPathValue == null then
      throw "smind.containers.docker.rootless.llmSocketPath must be set when rootless Podman is enabled"
    else
      rootlessPodmanSocketPathValue;
  rootlessPodmanSocketUri =
    if !rootlessPodmanEnabled then
      null
    else if rootlessPodmanSocketUriValue == null then
      throw "smind.containers.docker.rootless.llmSocketUri must be set when rootless Podman is enabled"
    else
      rootlessPodmanSocketUriValue;

  defaultCustomModelName = "huihui_ai/qwen3.5-abliterated:35b-custom";

  # Prompt content and validated skill files live in pkg/llm-prompts/.
  # Environment guidance is delivered as a skill for agents that support skills
  # (Claude Code, Codex, Gemini CLI, OpenCode). For agents without skill support
  # (Copilot, Vibe), a pre-composed context file from the package is used instead.
  llmPrompts = pkgs.callPackage "${cfg-meta.paths.pkg}/llm-prompts/default.nix" { };

  claudeMemoryText = lib.concatStringsSep "\n\n" config.smind.hm.dev.llm.memorySections;
  copilotConfig = jsonFormat.generate "copilot-config.json" {
    alt_screen = false;
    banner = "never";
    experimental = true;
    include_coauthor = config.smind.hm.dev.llm.coAuthored.enable;
    model = "gpt-5.4";
    theme = "dark";
    trusted_folders = [ ];
  };

in
{
  options = {
    smind.hm.dev.llm.enable = lib.mkEnableOption "LLM development environment variables";

    smind.hm.dev.llm.devstralContextSize = lib.mkOption {
      type = lib.types.int;
      default = 131072;
      description = "Context size for devstral model in opencode (default: 128k)";
    };

    smind.hm.dev.llm.opencodeDefaultModel = lib.mkOption {
      type = lib.types.str;
      default = defaultCustomModelName;
      description = "Default model for opencode";
    };

    smind.hm.dev.llm.opencodeOllamaModelName = lib.mkOption {
      type = lib.types.str;
      default = defaultCustomModelName;
      description = "Ollama model name configured for opencode provider";
    };

    smind.hm.dev.llm.memorySections = lib.mkOption {
      type = lib.types.listOf lib.types.lines;
      default = [ ];
      description = "Sections used to build Claude/Codex/Gemini memory text.";
    };

    smind.hm.dev.llm.coAuthored.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include Co-Authored-By: <llm> in commit message";
    };

    smind.hm.dev.llm.fullscreenTui.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable fullscreen TUI mode for agent CLIs that support it";
    };
  };

  config = lib.mkMerge [
    {
      smind.hm.dev.llm.devstralContextSize = lib.mkDefault (
        outerConfig.smind.llm.ollama.customContextLength or 131072
      );
      smind.hm.dev.llm.opencodeDefaultModel =
        lib.mkDefault config.smind.hm.dev.llm.opencodeOllamaModelName;
      smind.hm.dev.llm.memorySections = lib.mkBefore [ llmPrompts.baseContext ];
    }
    (lib.mkIf config.smind.hm.dev.llm.enable {
      home.sessionVariables = {
        OLLAMA_API_BASE = "http://127.0.0.1:11434";
        # AIDER_DARK_MODE = "true";
      };

      programs.claude-code = {
        enable = true;
        plugins = [ "${codexPluginCc}/plugins/codex" ];
        settings = {
          alwaysThinkingEnabled = true;
          theme = "dark";
          tui = lib.mkIf config.smind.hm.dev.llm.fullscreenTui.enable "fullscreen";
          permissions = {
            allow = [ "Edit(/tmp/**)" ];
          };
          includeCoAuthoredBy = config.smind.hm.dev.llm.coAuthored.enable;
          effortLevel = "high";
          model = "claude-opus-4-7[1m]";
          spinnerVerbs = {
            mode = "replace";
            verbs = [ "Working" ];
          };
          statusLine = {
            "type" = "command";
            "command" = ''
              CLAUDE_ACCOUNT="$(${pkgs.jq}/bin/jq -r '
                .oauthAccount.emailAddress //
                .oauthAccount.email //
                .oauthAccount.account.emailAddress //
                .oauthAccount.account.email //
                .oauthAccount.name //
                .oauthAccount.displayName //
                .oauthAccount.accountName //
                .account.emailAddress //
                .account.email //
                .account.name //
                empty
              ' "$HOME/.claude.json" 2>/dev/null)"
              if [ -z "$CLAUDE_ACCOUNT" ]; then
                CLAUDE_ACCOUNT="unknown-claude-account"
              fi
              printf '\033[2m\033[35m%s \033[0m\033[2m\033[37m%s \033[0m\033[2m@ %s \033[0m\033[2m\033[36min \033[1m\033[36m%s\033[0m' "$CLAUDE_ACCOUNT" "$(whoami)" "$(hostname -s)" "$(pwd | sed "s|^$HOME|~|")"
            '';
          };
        };
        skills = llmPrompts.skills;
        context = claudeMemoryText;
      };

      programs.codex = {
        enable = true;
        skills = llmPrompts.skills;
        context = claudeMemoryText;
        settings = {
          model = "gpt-5.4";
          model_reasoning_effort = "xhigh";
          project_doc_fallback_filenames = [ "CLAUDE.md" ];
          features.multi_agent = true;
          features.steer = true;
        };
      };

      home.file.".codex/config.toml".force = true;

      programs.gemini-cli = {
        enable = true;
        # nix-instantiate --eval -E 'builtins.fromJSON (builtins.readFile ~/.gemini/settings.json)'
        settings = {
          defaultModel = "gemini-3-pro-preview";
          general = {
            previewFeatures = true;
          };
          output = {
            format = "text";
          };
          security = {
            auth = {
              selectedType = "oauth-personal";
            };
          };
          tools = {
            autoAccept = true;
            shell = {
              showColor = true;
            };
          };
          ui = {
            footer = {
              hideContextPercentage = false;
            };
            showCitations = true;
            showLineNumbers = true;
            showMemoryUsage = true;
            showModelInfoInChat = true;
          };
          context.fileName = [
            "AGENTS.md"
            "CONTEXT.md"
            "GEMINI.md"
            "CLAUDE.md"
          ];
        };
        skills = llmPrompts.skills;
        context = {
          AGENTS = claudeMemoryText;
        };
      };

      home.file.".gemini-work/settings.json".source = config.home.file.".gemini/settings.json".source;
      home.file.".gemini-work/AGENTS.md".source = config.home.file.".gemini/AGENTS.md".source;

      home.file.".claude-work/settings.json".source = config.home.file.".claude/settings.json".source;
      home.file.".claude-work/CLAUDE.md".source = config.home.file.".claude/CLAUDE.md".source;

      # Copilot does not support skills — uses pre-composed context from llm-prompts package
      home.file.".copilot/copilot-instructions.md".source = llmPrompts.contextWithEnvFile;

      home.file.".copilot-work/copilot-instructions.md".source =
        config.home.file.".copilot/copilot-instructions.md".source;

      home.file.".vibe/config.toml".source = tomlFormat.generate "vibe-config.toml" {
        system_prompt_id = "default_with_custom_instructions";
      };

      # Vibe does not support skills — uses pre-composed context from llm-prompts package
      home.file.".vibe/prompts/default_with_custom_instructions.md".source =
        llmPrompts.contextWithEnvFile;

      programs.opencode = {
        enable = true;
        tui = {
          theme = "dark";
        };
        settings = {
          autoupdate = false;
          model = "ollama/minimax-m2.7";
          plugin = [ "opencode-gemini-auth@latest" ];
          provider = {
            google = {
              models = {
                "gemini-3-pro-preview" = {
                  options = {
                    thinkingConfig = {
                      thinkingLevel = "xhigh";
                      includeThoughts = true;
                    };
                  };
                };
              };
            };
            ollama = {
              npm = "@ai-sdk/openai-compatible";
              options = {
                baseURL = "http://127.0.0.1:11434/v1";
              };
              models = {
                "${config.smind.hm.dev.llm.opencodeOllamaModelName}" = {
                  limit = {
                    context = config.smind.hm.dev.llm.devstralContextSize;
                    output = config.smind.hm.dev.llm.devstralContextSize;
                  };
                };
              };
            };
          };
          permission = {
            read = "allow";
            edit = "allow";
            glob = "allow";
            list = "allow";
            grep = "allow";
            websearch = "allow";
            codesearch = "allow";
            bash = "allow";
            task = "allow";
            lsp = "allow";
            webfetch = "allow";
            skill = "allow";
            todoread = "allow";
            todowrite = "allow";
            external_directory = "allow";
            doom_loop = "allow";
          };
        };
        skills = llmPrompts.skills;
        context = claudeMemoryText;
      };

      # Linux-only: bubblewrap sandbox and yolo wrapper script
      home.packages = [
        pkgs.gh
        pkgs.github-copilot-cli
        pkgs.mistral-vibe
        pkgs.nodejs # required by claude-code plugins (.mjs scripts)
      ]
      ++ lib.optionals cfg-meta.isDarwin [
        inputs.claude-code-sandbox.packages."${pkgs.stdenv.hostPlatform.system}".default
      ]
      ++ lib.optionals cfg-meta.isLinux [
        # aichat
        # aider-chat
        # goose-cli
        pkgs.bubblewrap
        pkgs.reattach-llm

        (pkgs.callPackage "${cfg-meta.paths.pkg}/yolo/default.nix" {
          inherit copilotConfig;
          podmanSocketPath = if rootlessPodmanEnabled then rootlessPodmanSocketPath else null;
          podmanSocketUri = if rootlessPodmanEnabled then rootlessPodmanSocketUri else null;
        })
      ];
    })
  ];
}
