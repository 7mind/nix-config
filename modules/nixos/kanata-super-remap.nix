{ config, lib, pkgs, ... }:

let
  cfg = config.smind.keyboard.super-remap;
  buildKanataConfig = keyboardName: keyboardCfg:
    pkgs.runCommand "kanata-config-${keyboardName}"
      {
        extraDefCfg = keyboardCfg.extraDefCfg;
        passAsFile = [ "extraDefCfg" ];
      } ''
      mkdir -p $out
      cp ${./kanata-lib.kbd} $out/kanata-lib.kbd
      cp ${./kanata-lib-super-swap.kbd} $out/kanata-lib-super-swap.kbd

      echo "(defcfg" > $out/kanata.kbd
      cat "$extraDefCfgPath" >> $out/kanata.kbd
      echo ")" >> $out/kanata.kbd
      echo "" >> $out/kanata.kbd
      cat ${keyboardCfg.configFile} >> $out/kanata.kbd
    '';

  kanataConfigDirs = lib.mapAttrs buildKanataConfig cfg.kanata.keyboards;
  switcherKeyboards = lib.filterAttrs (_: keyboardCfg: keyboardCfg.port != null) cfg.kanata.keyboards;
  switcherKeyboardNames = lib.attrNames switcherKeyboards;
in
{
  options.smind.keyboard.super-remap = {
    enable = lib.mkEnableOption "Mac-style keyboard shortcuts via kanata";

    kanata = {
      keyboards = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            port = lib.mkOption {
              type = lib.types.nullOr lib.types.port;
              default = null;
              description = "Port for the kanata TCP server";
            };

            devices = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "kanata service devices";
            };

            extraDefCfg = lib.mkOption {
              type = lib.types.lines;
              default = ''
                process-unmapped-keys yes
                delegate-to-first-layer true
                concurrent-tap-hold true
              '';
              description = "Extra kanata defcfg entries prepended to this keyboard config";
            };

            configFile = lib.mkOption {
              type = lib.types.path;
              description = "Path to the kanata config file for this keyboard";
            };
          };
        });
        default = {
          default = {
            configFile = ./kanata-super-remap.kbd;
            port = 22334;
          };
        };
        description = "Per-keyboard kanata service configuration";
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
            "class" = "code|codium|VSCodium|dev.zed.Zed";
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
      assertions = [
        {
          assertion = cfg.kanata.keyboards != { };
          message = "smind.keyboard.super-remap.kanata.keyboards must define at least one keyboard";
        }
        {
          assertion = (!cfg.kanata-switcher.enable) || lib.length switcherKeyboardNames == 1;
          message = "smind.keyboard.super-remap.kanata-switcher requires exactly one keyboard with a non-null port";
        }
      ];

      environment.systemPackages = [ config.services.kanata.package ];

      services.kanata = {
        enable = true;
        keyboards = lib.mapAttrs
          (keyboardName: keyboardCfg:
            {
              devices = keyboardCfg.devices;
              config = "";
              configFile = "${kanataConfigDirs.${keyboardName}}/kanata.kbd";
            }
            // lib.optionalAttrs (keyboardCfg.port != null) {
              port = keyboardCfg.port;
            })
          cfg.kanata.keyboards;
      };

      systemd.services = lib.mapAttrs'
        (keyboardName: kanataConfigDir: lib.nameValuePair "kanata-${keyboardName}" {
          restartTriggers = [ kanataConfigDir ];
        })
        kanataConfigDirs;
    })

    (lib.mkIf (cfg.kanata-switcher.enable) {
      services.kanata-switcher = {
        enable = true;
        kanataPort = switcherKeyboards.${lib.head switcherKeyboardNames}.port;
        gnomeExtension.enable = false; # managed in gnome-extensions.nix
        settings = cfg.kanata-switcher.settings;
      };

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
