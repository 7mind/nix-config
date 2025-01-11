{ config, lib, ... }:

{
  options = {
    smind.hm.zsh.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.zsh.enable {
    # home.activation.zsh-cleanup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    #   echo >&2 "Cleaning up zsh junk..."
    #   rm -f ${config.home.homeDirectory}/.zshrc.zwc
    #   rm -rf ${config.home.homeDirectory}/.zcompdump* # get rid of outdated zsh junk
    # '';

    programs.starship = {
      enable = true;
      settings = {
        command_timeout = 300;
        scala.disabled = true;
      };
    };

    programs.zoxide = {
      enable = true;
      enableBashIntegration = true;
      enableZshIntegration = true;
    };

    programs.autojump = {
      enable = true;
      enableBashIntegration = true;
      enableZshIntegration = true;
    };

    # see any.nix, any-nixos.nix any-darwin.nix, and HM config in zsh.nix
    # https://home-manager-options.extranix.com/?query=programs.zsh&release=master
    programs.zsh = {
      enable = true;
      #zprof.enable = true;
      autocd = true;

      autosuggestion.enable = true;
      syntaxHighlighting.enable = true;

      history = {
        ignoreDups = true;
        share = true;
        size = 10000;
      };

      oh-my-zsh = {
        enable = true;
        theme = "kphoen";
        plugins = [ "zsh-navigation-tools" ];
      };

      localVariables = {
        COMPLETION_WAITING_DOTS = true;
        HIST_STAMPS = "yyyy-mm-dd";
      };

      sessionVariables = { };

      initExtra = ''
        _fzf_comprun () {
          local command = $1
          shift
          case "$command" in
              cd)           fzf "$@" --preview 'tree -C {} | head -200';;
              *)            fzf "$@" ;;
          esac
        }
      '';
    };

    programs.tealdeer = {
      enable = true;
      # updateOnActivation = false;
      settings = { updates = { auto_update = true; }; };
    };

    programs.fzf = {
      enable = true;
      enableZshIntegration = true;
      defaultCommand = "fd .$HOME";
      fileWidgetCommand = "$FZF_DEFAULT_COMMAND";
      changeDirWidgetCommand = "fd -t d . $HOME";
      defaultOptions = [
        "--layout=reverse"
        "--border"
        "--info=inline"
        "--height=80%"
        "--multi"
        "--preview-window=:hidden"
        "--preview '([[ -f {} ]] && (bat --style=numbers --color=always {} || cat {})) || ([[ -d {} ]] && (tree -C {} | less)) || echo {} 2> /dev/null | head -200'"
        "--color='hl:148,hl+:154,pointer:032,marker:010,bg+:237,gutter:008'"
        "--prompt='∼ '"
        "--pointer='▶'"
        "--marker='✓'"
        "--bind '?:toggle-preview'"
      ];
      tmux.enableShellIntegration = true;
    };
  };
}
