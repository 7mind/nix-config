{ config, lib, ... }:

let
  # WORDCHARS presets selected by smind.hm.zsh.wordchars; any unrecognised
  # value is used verbatim as the WORDCHARS string.
  wordcharsPresets = {
    "default" = "*?_-.[]~=&;!#$%^(){}<>";  # zsh's built-in default
    "no-hash" = "*?_-.[]~=&;!$%^(){}<>";   # zsh default with '#' as a word boundary
    "empty" = "";                          # bash-like: only alphanumerics delimit words
  };
  wordcharsValue =
    wordcharsPresets.${config.smind.hm.zsh.wordchars}
      or config.smind.hm.zsh.wordchars;
in
{
  options = {
    smind.hm.zsh.enable = lib.mkEnableOption "Zsh shell integrations";
    smind.hm.zsh.mac-keybindings = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Mac-style keybindings: Alt+Arrow for word navigation, Alt+Delete for word deletion";
    };
    smind.hm.zsh.intellij-keybindings = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "IntelliJ terminal Cmd+Left/Right for beginning/end of line";
    };
    smind.hm.zsh.wordchars = lib.mkOption {
      type = lib.types.str;
      default = "no-hash";
      example = "empty";
      description = ''
        Selects zsh's WORDCHARS, which punctuation counts as part of a word
        for word motions (forward-word, backward-kill-word, etc.). Recognised
        sentinels:
          "default" - zsh's built-in WORDCHARS (includes '#')
          "no-hash" - zsh default, but '#' acts as a word boundary
          "empty"   - only alphanumerics delimit words (bash-like boundaries)
        Any other value is used verbatim as the WORDCHARS string.
      '';
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

      initContent = lib.concatStringsSep "\n" [
        ''
          # Ghostty CWD inheritance requires short hostname, not FQDN.
          # NixOS sets HOST to FQDN when networking.domain is configured.
          # Uncomment if networking.domain is set and Ghostty splits open in ~ instead of CWD:
          # HOST=''${HOST%%.*}

          # alt+backspace deletes by word; punctuation in WORDCHARS counts as
          # word parts. Value chosen by the smind.hm.zsh.wordchars option.
          export WORDCHARS='${wordcharsValue}'

          # Ctrl-W: whitespace-delimited kill, like bash unix-word-rubout.
          # Alt-Backspace stays backward-kill-word (honours WORDCHARS above).
          # The *-match widgets are separate autoloadable functions; they must
          # be explicitly zle -N'd (select-word-style does NOT register them).
          autoload -Uz backward-kill-word-match match-words-by-style
          zle -N backward-kill-word-match
          zstyle ':zle:backward-kill-word-match' word-style whitespace
          bindkey "^W" backward-kill-word-match

          # enable carapace
          setopt menucomplete
          zstyle ':completion:*' menu select

          what() {
            ls -la `which $1`
          }
        ''
        (lib.optionalString config.smind.hm.zsh.intellij-keybindings ''
          # IntelliJ terminal Cmd+Left/Right
          bindkey "\e\eOD" beginning-of-line
          bindkey "\e\eOC" end-of-line
        '')
        (lib.optionalString config.smind.hm.zsh.mac-keybindings ''
          # Alt+Arrow: word navigation
          bindkey "\e[1;3D" backward-word
          bindkey "\e[1;3C" forward-word

          # Alt+Delete: delete word forward
          bindkey "\e[3;3~" kill-word

          # Ctrl+U: backward-kill-line (match bash behavior, zsh defaults to kill-whole-line)
          bindkey "^U" backward-kill-line
        '')
      ];
    };


    programs.atuin.enableZshIntegration = true;
  };
}
