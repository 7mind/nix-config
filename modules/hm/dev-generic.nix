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

    home.file.".claude/CLAUDE.md".text = ''
      ## Project Guidelines

      ### Core Principles
      - **Don't give up**: continue working until you can provide proper full-comprehensive solution
      - **Fail fast**: Use assertions, throw errors early. No graceful fallbacks or defensive programming
      - **Explicit over implicit**: No default parameters, no optional chaining for required values
      - **Type safety**: Use interfaces/classes, not tuples/any/dictionaries/etc
      - **SOLID**: adhere to SOLID principles
      - **RTFM**: read the documentation, code and samples of the libraries you work with

      ### Code Style
      - No magic constants - use named constants
      - No backwards compatibility concerns - refactor freely
      - Prefer composition over conditional logic

      ### Project Structure
      - Docs: `./docs/drafts/{timestamp}-{name}.md`
      - Debug scripts: `./debug/{timestamp}-{name}.ts`
      - Services: try to use interface + implementation pattern when possible
    '';

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
    ] ++ (if config.smind.hm.dev.tex.enable then [ texlive.combined.scheme-full ] else [ ]);
  };


}
