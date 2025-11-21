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
        # Only run if direnv has an active env
        [[ -z ''${DIRENV_FILE:-} ]] && return

        # Directory that contains the active .envrc
        local direnv_root=''${DIRENV_FILE:A:h}
        local proj_file="$direnv_root/.project-zsh"

        [[ -r "$proj_file" ]] || return

        # Avoid re-sourcing the same file repeatedly
        if [[ "$_LAST_PROJECT_ZSH" != "$proj_file" ]]; then
          _LAST_PROJECT_ZSH="$proj_file"
          source "$proj_file"
        fi
      }

      typeset -ag precmd_functions chpwd_functions
      precmd_functions=(_direnv_project_zsh_autoload $precmd_functions)
      chpwd_functions=(_direnv_project_zsh_autoload $chpwd_functions)
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
