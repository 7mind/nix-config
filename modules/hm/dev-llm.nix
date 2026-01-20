{ config, lib, pkgs, cfg-meta, osConfig, ... }:

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

          - **Sandboxed**: You run in a bubblewrap sandbox with access to the project directory, /nix, and /tmp/exchange
          - **Write restrictions**: Only write to the project directory and /tmp/exchange - all other locations are sandboxed and changes will be lost!
          - **Direct execution**: Always run project commands directly (compilation, tests, linting, git, formatting, etc.) - these work fine in the sandbox. Only use the script workflow for true sandbox escapes.
          - **For system interaction**: When you need to access $HOME, modify system configuration, or reach files outside the sandbox, use this workflow:
            1. Write a shell script to /tmp/exchange/{name}.sh
            2. Script structure MUST be:
               ```bash
               #!/usr/bin/env bash
               set -euxo pipefail
               bat --paging=never "$0"  # Show script contents first
               read -p "Press Enter to run, Ctrl+C to abort..."
               # Your commands here, with output captured:
               command 2>&1 | tee /tmp/exchange/{name}.out
               ```
            3. Ask user to run: `bash /tmp/exchange/{name}.sh`
            4. After user confirms execution, use Read tool to read /tmp/exchange/{name}.out
            5. NEVER proceed without reading the output file - it contains the information you need
          - **Verbose debug scripts**: Use `set -x` so the user can see commands together with output
          - **Nix environment**: Use flake.nix and direnv for dependencies
          - **Commands**: Use `direnv exec DIR COMMAND [...ARGS]` and `nix run`

          ### Code Style

          - **Type safety**: Encode domain concepts as named types (interfaces/classes/records), avoid catch-all types (Object, any) and untyped containers (string-keyed maps)
          - **SOLID**: Adhere to SOLID principles
          - **No magic constants**: Use named constants
          - **No backwards compatibility**: Refactor freely
          - **Composition over conditionals**: Prefer composition over conditional logic
          - **DRY**: Never duplicate, always generalize

          ### Project Structure

          - Docs: ./docs/drafts/{YYYYMMDD-HHMM}-{name}.md
          - Debug scripts: ./debug/{YYYYMMDD-HHMMSS}-{name}.{ext} (use appropriate extension for project language)
          - **Services**: Use interface + implementation pattern when possible
          - **Gitignore**: Always create and maintain reasonable .gitignore files

          ### Tools

          - **Debuggers**: Use gdb, lldb, jdb, pdb and any other debuggers
          - **Parallelism**: Use nproc to determine available parallel processes
          - **Unattended mode**: Always run tools in batch mode, especially tools like SBT which expect user input by default
        '';
      };

      programs.codex = {
        enable = true;
        custom-instructions = config.programs.claude-code.memory.text;
        settings = {
          project_doc_fallback_filenames = [ "CLAUDE.md" ];
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

      # Linux-only: bubblewrap sandbox and yolo-* wrapper scripts
      home.packages = lib.optionals cfg-meta.isLinux (with pkgs;
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
              --ro "''${HOME}/.config/direnv" \
              --ro "''${HOME}/.local/share/direnv" \
              --ro "''${HOME}/.direnvrc" \
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
              --ro "''${HOME}/.config/direnv" \
              --ro "''${HOME}/.local/share/direnv" \
              --ro "''${HOME}/.direnvrc" \
              "''${ENV_ARGS[@]}" \
              -- codex --dangerously-bypass-approvals-and-sandbox --search "''${CMD_ARGS[@]}"
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
              --ro "''${HOME}/.config/direnv" \
              --ro "''${HOME}/.local/share/direnv" \
              --ro "''${HOME}/.direnvrc" \
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
              --ro "''${HOME}/.config/direnv" \
              --ro "''${HOME}/.local/share/direnv" \
              --ro "''${HOME}/.direnvrc" \
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
              --ro "''${HOME}/.config/direnv" \
              --ro "''${HOME}/.local/share/direnv" \
              --ro "''${HOME}/.direnvrc" \
              "''${ENV_ARGS[@]}" \
              -- opencode "''${CMD_ARGS[@]}"
          '')
        ]);
    })
  ];
}
