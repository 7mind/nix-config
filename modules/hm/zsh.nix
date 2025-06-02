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
    programs.zoxide.enableZshIntegration = true;

    programs.wezterm.enableZshIntegration = true;

    programs.carapace.enableZshIntegration = true;

    # https://home-manager-options.extranix.com/?query=programs.zsh&release=master
    programs.zsh = {
      enable = true;
      #zprof.enable = true;

      autocd = true;
      syntaxHighlighting.enable = true;

      history = {
        ignoreDups = true;
        share = true;
        size = 10000;
      };

      # oh-my-zsh = {
      #   enable = true;
      #   theme = "kphoen";
      #   plugins = [ "zsh-navigation-tools" ];
      # };

      localVariables = {
        COMPLETION_WAITING_DOTS = true;
        HIST_STAMPS = "yyyy-mm-dd";
      };

      sessionVariables = { };

      initContent = ''
        # enable carapace
        setopt menucomplete
        zstyle ':completion:*' menu select

        what() {
          ls -la `which $1`
        }
      '';
    };


    programs.atuin.enableZshIntegration = true;
  };
}
