{ config, lib, pkgs, ... }:

let
  cfg = config.smind.keyboard.super-remap;

  # Bundle kanata config files together so includes work
  # Prepend defcfg with extraDefCfg settings to the main config
  kanataConfigDir = pkgs.runCommand "kanata-config"
    {
      extraDefCfg = cfg.kanata.extraDefCfg;
      passAsFile = [ "extraDefCfg" ];
    } ''
    mkdir -p $out
    cp ${./kanata-lib.kbd} $out/kanata-lib.kbd

    # Prepend defcfg block to the config file
    echo "(defcfg" > $out/kanata-super-remap.kbd
    cat "$extraDefCfgPath" >> $out/kanata-super-remap.kbd
    echo ")" >> $out/kanata-super-remap.kbd
    echo "" >> $out/kanata-super-remap.kbd
    cat ${cfg.kanata.configFile} >> $out/kanata-super-remap.kbd
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
        default = ./kanata-super-remap.kbd;
        description = "Path to kanata config file (will be bundled with kanata-lib.kbd for includes)";
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
            "class" = "kitty|alacritty|wezterm|com.mitchellh.ghostty";
            "layer" = "unmapped";
          }
          {
            "class" = "code|codium|VSCodium";
            "layer" = "unmapped";
          }
          {
            "class" = "jetbrains";
            "layer" = "unmapped";
          }
          {
            "class" = "Vmplayer|Vmware|virt-manager";
            "layer" = "unmapped";
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
          # extraDefCfg is prepended to configFile in kanataConfigDir
          configFile = "${kanataConfigDir}/kanata-super-remap.kbd";
        };
      };

      # Restart kanata when config changes
      systemd.services.kanata-default.restartTriggers = [
        kanataConfigDir
      ];
    })

    (lib.mkIf (cfg.kanata-switcher.enable) {
      services.kanata-switcher = {
        enable = true;
        kanataPort = cfg.kanata.port;
        gnomeExtension.enable = false; # managed in gnome-extensions.nix
        settings = cfg.kanata-switcher.settings;
      };

      # restartTriggers adds X-Restart-Triggers to unit file, but NixOS doesn't
      # process it for user services - only system services are handled.
      # See: https://github.com/NixOS/nixpkgs/issues/246611
      systemd.user.services.kanata-switcher.restartTriggers = [
        (builtins.toJSON cfg.kanata-switcher.settings)
      ];

      # Workaround: restart kanata-switcher for all active users during activation
      # Always restart on every switch (hash-based detection doesn't work reliably)
      system.activationScripts.restart-kanata-switcher = ''
        echo "Restarting kanata-switcher for all logged-in users..."
        for uid in $(${pkgs.systemd}/bin/loginctl list-users --no-legend 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $1}'); do
          user=$(${pkgs.systemd}/bin/loginctl show-user "$uid" -p Name --value 2>/dev/null || true)
          if [ -n "$user" ] && [ "$user" != "root" ] && [ -d "/run/user/$uid" ]; then
            echo "  Restarting kanata-switcher for $user (uid $uid)"
            ${pkgs.util-linux}/bin/runuser -u "$user" -- \
              env XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
              ${pkgs.systemd}/bin/systemctl --user restart kanata-switcher.service 2>&1 || true
          fi
        done
      '';
    })
  ];
}
