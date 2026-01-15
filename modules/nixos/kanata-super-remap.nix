{ config, lib, pkgs, ... }:

let
  cfg = config.smind.keyboard.super-remap;

  # Bundle kanata config files together so includes work
  # Prepend defcfg with extraDefCfg settings to the main config
  mkKanataConfigDir = extraDefCfg: pkgs.runCommand "kanata-config"
    {
      inherit extraDefCfg;
      passAsFile = [ "extraDefCfg" ];
    } ''
    mkdir -p $out
    cp ${./kanata-lib.kbd} $out/kanata-lib.kbd

    # Prepend defcfg block to the config file
    echo "(defcfg" > $out/kanata-super-remap.kbd
    cat "$extraDefCfgPath" >> $out/kanata-super-remap.kbd
    echo ")" >> $out/kanata-super-remap.kbd
    echo "" >> $out/kanata-super-remap.kbd
    cat ${./kanata-super-remap.kbd} >> $out/kanata-super-remap.kbd
  '';
in
{
  options.smind.keyboard.super-remap = {
    enable = lib.mkEnableOption "Mac-style keyboard shortcuts via kanata";

    kanata = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 22334;
        description = "Port for kanata TCP server";
      };

      devices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "kanata service devices";
      };

      extraDefCfg = lib.mkOption {
        type = lib.types.str;
        default = ''
          process-unmapped-keys yes
          delegate-to-first-layer true
          concurrent-tap-hold true
        '';
        description = "kanata service extraDefCfg";
      };

      configFile = lib.mkOption {
        type = lib.types.path;
        default = "${mkKanataConfigDir cfg.kanata.extraDefCfg}/kanata-super-remap.kbd";
        defaultText = lib.literalExpression ''"''${mkKanataConfigDir cfg.kanata.extraDefCfg}/kanata-super-remap.kbd"'';
        description = "Path to kanata config file (must be in same directory as kanata-lib.kbd for includes to work)";
      };
    };

    kanata-switcher = {
      enable = lib.mkEnableOption "kanata-switcher for automatic layer switching";

      settings = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [
          {
            "default" = "default";
          }
          {
            "class" = "firefox|chromium-browser|brave-browser";
            "layer" = "browser";
          }
          {
            "class" = "kitty|alacritty|wezterm|com.mitchellh.ghostty";
            "layer" = "terminal";
          }
          {
            "class" = "code|jetbrains|codium|VSCodium";
            "layer" = "ide";
          }
        ];
        description = "Layer switching rules for kanata-switcher";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ config.services.kanata.package ];

      services.kanata = {
        enable = true;
        keyboards.default = {
          devices = cfg.kanata.devices;
          port = cfg.kanata.port;
          # extraDefCfg is prepended to configFile by mkKanataConfigDir
          configFile = cfg.kanata.configFile;
        };
      };

      # Restart kanata when config changes
      systemd.services.kanata-default.restartTriggers = [
        cfg.kanata.configFile
        cfg.kanata.extraDefCfg
      ];
    })

    (lib.mkIf (cfg.kanata-switcher.enable) {
      services.kanata-switcher = {
        enable = true;
        kanataPort = cfg.kanata.port;
        gnomeExtension.enable = false; # managed in gnome-extensions.nix
        settings = cfg.kanata-switcher.settings;
      };

      # restartTriggers doesn't work for user services (NixOS limitation)
      # https://github.com/NixOS/nixpkgs/issues/246611
      # Workaround: embed settings hash in the service environment to force unit file change
      systemd.user.services.kanata-switcher.environment.KANATA_SWITCHER_CONFIG_HASH =
        builtins.hashString "sha256" (builtins.toJSON cfg.kanata-switcher.settings);
    })
  ];
}
