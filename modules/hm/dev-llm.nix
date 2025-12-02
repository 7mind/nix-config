{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.hm.dev.llm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.dev.llm.enable {
    home.sessionVariables = {
      OLLAMA_API_BASE = "http://127.0.0.1:11434";
      AIDER_DARK_MODE = "true";
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
      '';
    };

    programs.codex = {
      enable = true;
      custom-instructions = config.programs.claude-code.memory.text;
    };


    programs.gemini-cli = {
      enable = true;
      # nix-instantiate --eval -E 'builtins.fromJSON (builtins.readFile ~/.gemini/settings.json)'
      settings = {
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
      };
      context = {
        AGENTS = config.programs.claude-code.memory.text;
      };
    };

    home.file.".gemini-work/settings.json".source = config.home.file.".gemini/settings.json".source;
    home.file.".gemini-work/AGENTS.md".source = config.home.file.".gemini/AGENTS.md".source;
    home.packages = with pkgs;
      let
        inherit (pkgs) firejail-wrap;
      in
      [
        bubblewrap

        # aichat
        # aider-chat
        # opencode
        # goose-cli

        (writeShellScriptBin "yolo-claude" ''
          exec ${firejail-wrap}/bin/firejail-wrap \
            --rw "''${PWD}" \
            --rw "''${HOME}/.claude" \
            --rw "''${HOME}/.claude.json" \
            --rw "''${HOME}/.config/claude" \
            --rw "''${HOME}/.cache" \
            --ro "''${HOME}/.config/git" \
            --ro /nix/store \
            --ro /nix/var \
            -- claude --permission-mode bypassPermissions "$@"
        '')

        (writeShellScriptBin "yolo-codex" ''
          exec ${firejail-wrap}/bin/firejail-wrap \
            --rw "''${PWD}" \
            --rw "''${HOME}/.codex" \
            --rw "''${HOME}/.config/codex" \
            --rw "''${HOME}/.cache" \
            --ro "''${HOME}/.config/git" \
            --ro /nix/store \
            --ro /nix/var \
            -- codex --dangerously-bypass-approvals-and-sandbox "$@"
        '')

        (writeShellScriptBin "yolo-gemini" ''
          exec ${firejail-wrap}/bin/firejail-wrap \
            --rw "''${PWD}" \
            --rw "''${HOME}/.gemini" \
            --rw "''${HOME}/.cache" \
            --ro "''${HOME}/.config/git" \
            --ro /nix/store \
            --ro /nix/var \
            -- gemini --yolo "$@"
        '')

        (writeShellScriptBin "yolo-gemini-work" ''
          exec ${firejail-wrap}/bin/firejail-wrap \
            --rw "''${PWD}" \
            --rw "''${HOME}/.gemini-work" \
            --rw "''${HOME}/.cache" \
            --ro "''${HOME}/.config/git" \
            --ro /nix/store \
            --ro /nix/var \
            --bind "''${HOME}/.gemini-work,''${HOME}/.gemini" \
            -- gemini --yolo "$@"
        '')
      ];
  };


}
