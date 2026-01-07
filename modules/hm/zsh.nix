{ config, lib, ... }:

{
  options = {
    smind.hm.zsh.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Zsh shell integrations";
    };
  };

  config = lib.mkIf config.smind.hm.zsh.enable {
    programs.zoxide.enableZshIntegration = true;

    programs.wezterm.enableZshIntegration = config.smind.hm.wezterm.enable;

    programs.ghostty.enableZshIntegration = true;

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
        # Ghostty CWD inheritance requires short hostname, not FQDN.
        # NixOS sets HOST to FQDN when networking.domain is configured.
        # Uncomment if networking.domain is set and Ghostty splits open in ~ instead of CWD:
        # HOST=''${HOST%%.*}

        # alt+backspace deletes by word, symbols in this list ARE word parts
        #export WORDCHARS='*?_-.[]~=&;!#$%^(){}<>'
        export WORDCHARS='*?_-.[]~=&;!$%^(){}<>'

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
