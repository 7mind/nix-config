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

    programs.zsh.initContent = ''
      _direnv_project_zsh_autoload() {
        # Only do anything if direnv has an active env
        local direnv_dir="''${DIRENV_DIR:-}"
        [[ -z "$direnv_dir" ]] && return

        local proj_file="$direnv_dir/.project-zsh"
        [[ ! -f "$proj_file" ]] && return  # no per-project zsh config, nothing to do

        # Avoid re-sourcing for the same project in this shell
        if [[ "$_DIRENV_PROJECT_ZSH_LOADED" != "$proj_file" ]]; then
          source "$proj_file"
          _DIRENV_PROJECT_ZSH_LOADED="$proj_file"
        fi
      }

      autoload -Uz add-zsh-hook
      # Run *after* direnv’s own precmd logic, once per prompt
      add-zsh-hook precmd _direnv_project_zsh_autoload
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

      python3
    ] ++ (if config.smind.hm.dev.tex.enable then [ texlive.combined.scheme-full ] else [ ]);
  };


}
