{ cfg-const, config, lib, pkgs, xdg_associate, cfg-meta, outerConfig, ... }:

{
  options = {
    smind.hm.environment.sane-defaults.generic.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "";
    };

    smind.hm.environment.all-docs.enable = lib.mkOption {
      type = lib.types.bool;
      default = outerConfig.smind.isDesktop;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.environment.sane-defaults.generic.enable {
    manual = lib.mkIf config.smind.hm.environment.all-docs.enable {
      html.enable = true;
    };

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

    programs.atuin = {
      enable = true;
      settings = {
        auto_sync = true;
        sync_frequency = "5m";
        sync_address = "https://atn.net.7mind.io";

        enter_accept = false;
        prefers_reduced_motion = true;

        smart_sort = true;
        search_mode = "skim";
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

    home.shellAliases = cfg-const.universal-aliases // { };

    home.packages = lib.mkIf cfg-meta.isLinux (with pkgs; [
      imagemagick
    ]);

  };


}
