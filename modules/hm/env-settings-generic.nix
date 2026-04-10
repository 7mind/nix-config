{ cfg-const, config, lib, pkgs, xdg_associate, cfg-meta, outerConfig, ... }:

{
  options = {
    smind.hm.environment.sane-defaults.generic.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable generic home-manager environment settings";
    };

    smind.hm.environment.all-docs.enable = lib.mkOption {
      type = lib.types.bool;
      default = outerConfig.smind.isDesktop;
      description = "Install documentation and man pages";
    };

    smind.hm.environment.television.enable = lib.mkEnableOption "television fuzzy finder (replaces fzf)";
  };

  config = lib.mkIf config.smind.hm.environment.sane-defaults.generic.enable {
    home.enableNixpkgsReleaseCheck = false;


    # SSH agent: use Home Manager's ssh-agent only if system keyring uses "standalone" or is disabled
    # When system uses gcr-ssh-agent (GNOME/COSMIC), don't start a competing agent
    services.ssh-agent.enable = lib.mkIf cfg-meta.isLinux (
      let
        keyringCfg = outerConfig.smind.security.keyring or { };
        keyringEnabled = keyringCfg.enable;
        sshAgent = keyringCfg.sshAgent or "standalone";
      in
      # If keyring is not enabled, always use standalone ssh-agent
      # Otherwise, only use it if keyring explicitly sets sshAgent = "standalone"
      !keyringEnabled || sshAgent == "standalone"
    );

    programs.ssh.matchBlocks."*".addKeysToAgent = lib.mkIf cfg-meta.isLinux "yes";

    programs.zoxide = {
      enable = true;
      enableBashIntegration = true;
    };

    programs.starship = {
      enable = true;
      settings = {
        command_timeout = 300;
        scala.disabled = true;
        add_newline = true;
        character = {
          success_symbol = "[➜](bold green)";
          error_symbol = "[➜](bold red)";
        };
        directory = {
          style = "bold cyan";
          truncation_length = 5;
          truncate_to_repo = false;
          truncation_symbol = "…/";
          before_repo_root_style = "dimmed white";
          # https://github.com/starship/starship/issues/6179
          repo_root_style = "bold cyan";
        };
        hostname = {
          ssh_only = false;
        };
        username = {
          show_always = true;
          format = "[$user]($style) @ ";
        };
      };
    };

    programs.zsh = {
      initContent = lib.mkIf config.programs.fzf.enable ''
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

    programs.television = lib.mkIf config.smind.hm.environment.television.enable {
      enable = true;
      enableZshIntegration = true;
      channels.edit = {
        metadata = {
          name = "edit";
          description = "Fuzzy find a file and open it in $EDITOR";
          requirements = [ "fd" "bat" ];
        };
        source = {
          command = [ "fd -t f" "fd -t f -H" ];
        };
        preview = {
          command = "bat -n --color=always '{}'";
          env = { BAT_THEME = "ansi"; };
        };
        keybindings = {
          enter = "actions:edit";
        };
        actions.edit = {
          description = "Opens the selected entry with the default editor";
          command = "\${EDITOR:-vim} '{}'";
          shell = "bash";
          mode = "execute";
        };
      };
    };

    programs.fzf = {
      enable = lib.mkDefault (!config.smind.hm.environment.television.enable && !config.smind.hm.roles.desktop);
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

    programs.atuin = {
      enable = lib.mkDefault config.smind.hm.roles.desktop;
      settings = {
        auto_sync = true;
        sync_frequency = "5m";
        sync_address = "https://atn.net.7mind.io";

        enter_accept = false;
        prefers_reduced_motion = true;

        smart_sort = true;
        search_mode = "skim";
        style = "full";
        inline_height = 0; # use alternate terminal mode
      };
    };

    programs.carapace = {
      enable = true;
    };

    programs.tealdeer = {
      enable = true;
      # updateOnActivation = false;
      settings = { updates = { auto_update = true; }; };
    };

    home.shellAliases = cfg-const.universal-aliases
      // lib.optionalAttrs config.smind.hm.environment.television.enable {
        fzf = "tv";
        tve = "tv edit";
      };

    home.packages = lib.mkIf cfg-meta.isLinux (with pkgs; [
      imagemagick
    ]);

  };


}
