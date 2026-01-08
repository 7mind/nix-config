{ config, lib, pkgs, cfg-meta, osConfig, ... }:

{
  options = {
    smind.hm.dev.llm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable LLM development environment variables";
    };

    smind.hm.dev.llm.devstralContextSize = lib.mkOption {
      type = lib.types.int;
      default = 131072;
      description = "Context size for devstral model in opencode (default: 128k)";
    };

    smind.hm.dev.llm.opencodeDefaultModel = lib.mkOption {
      type = lib.types.str;
      default = "ollama/devstral:24b-small-2505-custom";
      description = "Default model for opencode";
    };
  };

  config = lib.mkMerge [
    {
      smind.hm.dev.llm.devstralContextSize = lib.mkDefault (osConfig.smind.llm.ollama.customContextLength or 131072);
    }
    (lib.mkIf config.smind.hm.dev.llm.enable {
      home.sessionVariables = {
        OLLAMA_API_BASE = "http://127.0.0.1:11434";
        # AIDER_DARK_MODE = "true";
      };

      programs.claude-code = {
        enable = true;
        settings = {
          alwaysThinkingEnabled = true;
          theme = "dark";
          permissions = {
            allow = [ "Edit(/tmp/**)" ];
          };
          includeCoAuthoredBy = true;
          #model = "claude-3-5-sonnet-20241022";
          statusLine = {
            "type" = "command";
            "command" = "printf '\\033[2m\\033[37m%s \\033[0m\\033[2m@ %s \\033[0m\\033[2m\\033[36min \\033[1m\\033[36m%s\\033[0m' \"$(whoami)\" \"$(hostname -s)\" \"$(pwd | sed \"s|^$HOME|~|\")\"";
          };
        };
        memory.text = ''
          ## Project Guidelines

          ### Core Principles

          - **Don't give up**: Provide comprehensive solutions
          - **Fail fast**: Use assertions, throw errors early - no graceful fallbacks
          - **Explicit over implicit**: No default parameters or optional chaining for required values
          - **Minimal comments**: Only write comments to explain something non-obvious
          - **No workarounds**: Deliver sound, generic, universal solutions. When you discover a bug or problem, don't hide it - attempt to fix underlying issues, ask for assistance when you can't
          - **Ask questions**: When instructions or requirements are unclear, incomplete, or contradictory - always ask for clarifications before proceeding

          ### References

          - **RTFM**: Read documentation, code, and samples thoroughly, download docs when necessary, use search
          - **Prefer recent docs**: When searching, prioritize results from the current year over older sources

          ### Environment

          - **Sandboxed**: You run in a bubblewrap sandbox and cannot read files in $HOME nor interact with the system. You can only observe the project and files in /nix. /tmp/exchange is also available
          - **Prepare scripts for user**: When you need to interact with the system, prepare a shell script that writes output to /tmp/exchange, ask user to run it, then read the output
          - **Verbose debug scripts**: Use `set -x` so the user can see commands together with output
          - Use nix environment with flake.nix and direnv for dependencies
          - Use `direnv exec DIR COMMAND [...ARGS]` and `nix run`

          ### Code Style

          - **Type safety**: Use interfaces/classes/records/data classes, avoid tuples/any/dictionaries
          - **SOLID**: Adhere to SOLID principles
          - No magic constants - use named constants
          - No backwards compatibility concerns - refactor freely
          - Prefer composition over conditional logic
          - Never duplicate, always generalize

          ### Project Structure

          - Docs: ./docs/drafts/{YYYYMMDD-HHMM}-{name}.md
          - Debug scripts: ./debug/{YYYYMMDD-HHMMSS}-{name}.{ext} (use appropriate extension for project language)
          - Services: Use interface + implementation pattern when possible
          - Always create and maintain reasonable .gitignore files

          ### Tools

          - Use debuggers! You can use gdb, lldb, jdb, pdb and any other debuggers!
          - Use nproc when you need to figure out how many parallel processes you can run
          - Always run tools in unattended/batch mode, especially tools like SBT which expect user input by default!
        '';
      };

      programs.codex = {
        enable = true;
        custom-instructions = config.programs.claude-code.memory.text;
        settings = {
          project_doc_fallback_filenames = [ "CLAUDE.md" ];
        };
      };


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
            auth = { selectedType = "oauth-personal"; };
          };
          tools = {
            autoAccept = true;
            shell = { showColor = true; };
          };
          ui = {
            footer = { hideContextPercentage = false; };
            showCitations = true;
            showLineNumbers = true;
            showMemoryUsage = true;
            showModelInfoInChat = true;
          };
          context.fileName = [ "AGENTS.md" "CONTEXT.md" "GEMINI.md" "CLAUDE.md" ];
        };
        context = {
          AGENTS = config.programs.claude-code.memory.text;
        };
      };

      home.file.".gemini-work/settings.json".source = config.home.file.".gemini/settings.json".source;
      home.file.".gemini-work/AGENTS.md".source = config.home.file.".gemini/AGENTS.md".source;

      programs.opencode = {
        enable = true;
        settings = {
          theme = "dark";
          autoupdate = "notify";
          model = config.smind.hm.dev.llm.opencodeDefaultModel;
          plugin = [ "opencode-gemini-auth@latest" ];
          provider = {
            google = {
              models = {
                "gemini-3-pro-preview" = {
                  options = {
                    thinkingConfig = {
                      thinkingLevel = "high";
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
                "devstral:24b-small-2505-custom" = {
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
        rules = config.programs.claude-code.memory.text;
      };

      home.packages = with pkgs;
        let
          inherit (pkgs) firejail-wrap;
        in
        [
          bubblewrap

          # aichat
          # aider-chat
          # goose-cli

          (writeShellScriptBin "yolo-claude" ''
            ENV_ARGS=()
            CMD_ARGS=()
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done
            exec ${firejail-wrap}/bin/firejail-wrap \
              --rw "''${PWD}" \
              --rw "''${HOME}/.claude" \
              --rw "''${HOME}/.claude.json" \
              --rw "''${HOME}/.config/claude" \
              --rw "''${HOME}/.cache" \
              --ro "''${HOME}/.config/git" \
              "''${ENV_ARGS[@]}" \
              -- claude --permission-mode bypassPermissions "''${CMD_ARGS[@]}"
          '')

          (writeShellScriptBin "yolo-codex" ''
            ENV_ARGS=()
            CMD_ARGS=()
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done
            exec ${firejail-wrap}/bin/firejail-wrap \
              --rw "''${PWD}" \
              --rw "''${HOME}/.codex" \
              --rw "''${HOME}/.config/codex" \
              --rw "''${HOME}/.cache" \
              --ro "''${HOME}/.config/git" \
              "''${ENV_ARGS[@]}" \
              -- codex --dangerously-bypass-approvals-and-sandbox "''${CMD_ARGS[@]}"
          '')

          (writeShellScriptBin "yolo-gemini" ''
            ENV_ARGS=()
            CMD_ARGS=()
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done
            exec ${firejail-wrap}/bin/firejail-wrap \
              --rw "''${PWD}" \
              --rw "''${HOME}/.gemini" \
              --rw "''${HOME}/.cache" \
              --ro "''${HOME}/.config/git" \
              "''${ENV_ARGS[@]}" \
              -- gemini --yolo "''${CMD_ARGS[@]}"
          '')

          (writeShellScriptBin "yolo-gemini-work" ''
            ENV_ARGS=()
            CMD_ARGS=()
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done
            exec ${firejail-wrap}/bin/firejail-wrap \
              --rw "''${PWD}" \
              --rw "''${HOME}/.gemini-work" \
              --rw "''${HOME}/.cache" \
              --ro "''${HOME}/.config/git" \
              "''${ENV_ARGS[@]}" \
              --bind "''${HOME}/.gemini-work,''${HOME}/.gemini" \
              -- gemini --yolo "''${CMD_ARGS[@]}"
          '')

          (writeShellScriptBin "yolo-opencode" ''
            ENV_ARGS=()
            CMD_ARGS=()
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --env) ENV_ARGS+=(--env "$2"); shift 2 ;;
                *) CMD_ARGS+=("$1"); shift ;;
              esac
            done
            exec ${firejail-wrap}/bin/firejail-wrap \
              --rw "''${PWD}" \
              --rw "''${HOME}/.config/opencode" \
              --rw "''${HOME}/.local/share/opencode" \
              --rw "''${HOME}/.cache" \
              --ro "''${HOME}/.config/git" \
              "''${ENV_ARGS[@]}" \
              -- opencode "''${CMD_ARGS[@]}"
          '')
        ];
    })
  ];
}
