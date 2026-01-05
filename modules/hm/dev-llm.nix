{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.hm.dev.llm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable LLM development environment variables";
    };
  };

  config = lib.mkIf config.smind.hm.dev.llm.enable {
    home.sessionVariables = {
      OLLAMA_API_BASE = "http://127.0.0.1:11434";
      # AIDER_DARK_MODE = "true";
    };

    programs.claude-code = {
      enable = true;
      settings = {
        alwaysThinkingEnabled = true;
        theme = "dark";
        permissions = { };
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

        - Use nix environment with flake.nix and direnv for dependencies
        - Use `direnv exec DIR COMMAND [...ARGS]` and `nix run`
        - **Don't give up**: Provide comprehensive solutions
        - **Fail fast**: Use assertions, throw errors early - no graceful fallbacks
        - **Explicit over implicit**: No default parameters or optional chaining for required values
        - **Type safety**: Use interfaces/classes/records/data classes, avoid tuples/any/dictionaries
        - **SOLID**: Adhere to SOLID principles
        - **RTFM**: Read documentation, code, and samples thoroughly, download docs when necessary
        - Don't write obvious comments. Only write comments to explain something important
        - Deliver sound, generic, universal solutions. Avoid workarounds.
        - **Ask questions**: when instructions or requirements are unclear or incomplete or you see contradictions - always ask for clarifications before proceeding.
        - **No workarounds**: whey you discover a bug or a problem, don't hide it. Attempt to fix underlying issues, ask for assistance when you can't

        ### Code Style

        - No magic constants - use named constants
        - No backwards compatibility concerns - refactor freely
        - Prefer composition over conditional logic
        - Never duplicate, always generalize

        ### Project Structure

        - Docs: ./docs/drafts/{timestamp}-{name}.md
        - Debug scripts: ./debug/{timestamp}-{name}.ts
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
        model = "anthropic/claude-opus-4-5";
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
  };


}
