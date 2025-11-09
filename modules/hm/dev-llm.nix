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
        - **Type safety**: Use interfaces/classes, avoid tuples/any/dictionaries
        - **SOLID**: Adhere to SOLID principles
        - **RTFM**: Read documentation, code, and samples thoroughly

        ### Code Style

        - No magic constants - use named constants
        - No backwards compatibility concerns - refactor freely
        - Prefer composition over conditional logic

        ### Project Structure

        - Docs: ./docs/drafts/{timestamp}-{name}.md
        - Debug scripts: ./debug/{timestamp}-{name}.ts
        - Services: Use interface + implementation pattern when possible
        - Always create and maintain reasonable .gitignore files
      '';
    };

    home.packages = with pkgs; [
      aider-chat
      claude-code

      aichat
      aider-chat
      # opencode
      goose-cli
      codex

      (writeShellScriptBin "yolo-claude" ''
        set -e

        CANDIDATE_PATHS=(
          "''${PWD}"
          "''${HOME}/.claude"
          "''${HOME}/.claude.json"
          "''${HOME}/.config/claude"
          "''${HOME}/.cache"
          /nix/store
          /nix/var
        )

        WHITELIST_ARGS=()
        for path in "''${CANDIDATE_PATHS[@]}"; do
          if [[ -e "$path" ]]; then
            WHITELIST_ARGS+=(--whitelist="$path")
          fi
        done

        firejail --noprofile "''${WHITELIST_ARGS[@]}" claude --permission-mode bypassPermissions "$@"
      '')
    ];
  };


}
