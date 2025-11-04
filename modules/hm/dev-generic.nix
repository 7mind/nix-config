{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.hm.dev.generic.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };

    smind.hm.dev.tex.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.dev.generic.enable {
    home.sessionVariables = {
      DOTNET_CLI_TELEMETRY_OPTOUT = "1";
    };

    home.sessionPath = lib.mkIf cfg-meta.isDarwin [
      "/opt/homebrew/bin"
      "${config.home.homeDirectory}/.rd/bin"
    ];

    # programs.zsh.envExtra = lib.mkIf cfg-meta.isDarwin ''
    #   export PATH=$PATH:~/.rd/bin
    # '';

    # programs.bash = lib.mkIf cfg-meta.isDarwin {
    #   enable = true;
    #   initExtra = ''
    #     export PATH=$PATH:~/.rd/bin
    #   '';
    # };

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
      '';
    };

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
      config = {
        whitelist.prefix = [ "~/work/safe" ];
      };
    };

    home.packages = with pkgs; [
      slack
      # zoom-us
      # gitFull

      websocat
      jq

      tokei
      cloc

      # bitwarden-cli
      # rbw
      bws

      aider-chat
      python3
      claude-code
    ] ++ (if config.smind.hm.dev.tex.enable then [ texlive.combined.scheme-full ] else [ ]);
  };


}
