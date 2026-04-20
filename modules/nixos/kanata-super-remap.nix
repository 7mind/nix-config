{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.smind.keyboard.super-remap;
  owner = config.smind.host.owner;
  defaultKanataSwitcherSettings = [
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
  buildKanataConfig =
    keyboardName: keyboardCfg:
    pkgs.runCommand "kanata-config-${keyboardName}"
      {
        extraDefCfg = keyboardCfg.extraDefCfg;
        passAsFile = [ "extraDefCfg" ];
      }
      ''
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
  # Skip kanata-switcher entirely when owner is unset. The switcher's systemd unit
  # needs a concrete user, so we can't produce a valid config otherwise.
  switcherKeyboards = lib.optionalAttrs (owner != null) (lib.filterAttrs (
    _: keyboardCfg: keyboardCfg.kanata-switcher.enable && keyboardCfg.port != null
  ) cfg.kanata.keyboards);
  switcherKeyboardNames = lib.attrNames switcherKeyboards;
  switcherServiceNames = map (
    keyboardName: "kanata-switcher-${keyboardName}.service"
  ) switcherKeyboardNames;
  nonNullPorts = lib.filter (p: p != null) (
    lib.mapAttrsToList (_: kb: kb.port) cfg.kanata.keyboards
  );
  switcherModuleKeyboards = lib.mapAttrs (
    keyboardName: keyboardCfg:
    let
      switcherCfg = keyboardCfg.kanata-switcher;
    in
    {
      kanataPort = keyboardCfg.port;
      settings = switcherCfg.settings;
      logging = if switcherCfg.verbose then "none" else "quiet-focus";
    }
  ) switcherKeyboards;
in
{
  options.smind.keyboard.super-remap = {
    enable = lib.mkEnableOption "Mac-style keyboard shortcuts via kanata";

    kanata = {
      keyboards = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              port = lib.mkOption {
                type = lib.types.nullOr lib.types.port;
                default = 22334;
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
                default = ./kanata-super-remap.kbd;
                description = "Path to the kanata config file for this keyboard";
              };

              kanata-switcher = {
                enable = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Enable kanata-switcher for automatic layer switching on this keyboard";
                };
                verbose = lib.mkEnableOption "disable --quiet-focus";
                settings = lib.mkOption {
                  type = lib.types.listOf lib.types.attrs;
                  default = defaultKanataSwitcherSettings;
                  description = "Layer switching rules for kanata-switcher";
                };
              };
            };
          }
        );
        default = {
          default = { };
        };
        description = "Per-keyboard kanata service configuration";
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
          assertion = builtins.length nonNullPorts == builtins.length (lib.unique nonNullPorts);
          message = "smind.keyboard.super-remap.kanata.keyboards: port conflict — each keyboard must use a unique port. Current assignments: ${
            lib.concatStringsSep ", " (lib.mapAttrsToList (name: kb: "${name}=${toString kb.port}") (lib.filterAttrs (_: kb: kb.port != null) cfg.kanata.keyboards))
          }";
        }
      ]
      ++ lib.mapAttrsToList (keyboardName: keyboardCfg: {
        assertion = (!keyboardCfg.kanata-switcher.enable) || keyboardCfg.port != null;
        message = "smind.keyboard.super-remap.kanata.keyboards.${keyboardName}.kanata-switcher requires a non-null port";
      }) cfg.kanata.keyboards;

      warnings = lib.optional
        (owner == null && lib.any (kb: kb.kanata-switcher.enable && kb.port != null) (lib.attrValues cfg.kanata.keyboards))
        "smind.keyboard.super-remap.kanata-switcher is configured but smind.host.owner is null; skipping switcher setup.";

      environment.systemPackages = [ config.services.kanata.package ];

      services.kanata = {
        enable = true;
        keyboards = lib.mapAttrs (
          keyboardName: keyboardCfg:
          {
            devices = keyboardCfg.devices;
            config = "";
            configFile = "${kanataConfigDirs.${keyboardName}}/kanata.kbd";
          }
          // lib.optionalAttrs (keyboardCfg.port != null) {
            port = keyboardCfg.port;
          }
        ) cfg.kanata.keyboards;
      };

      systemd.services = lib.mapAttrs' (
        keyboardName: kanataConfigDir:
        lib.nameValuePair "kanata-${keyboardName}" {
          restartTriggers = [ kanataConfigDir ];
          serviceConfig = {
            Restart = "on-failure";
            RestartSec = 5;
          };
        }
      ) kanataConfigDirs;
    })

    (lib.mkIf (cfg.enable && switcherKeyboardNames != [ ]) {
      services.kanata-switcher = {
        enable = true;
        gnomeExtension.enable = false; # managed in gnome-extensions.nix
        keyboards = switcherModuleKeyboards;
      };
      environment.systemPackages = [
        config.services.kanata-switcher.package
      ]
      ++ lib.optional config.services.kanata-switcher.gnomeExtension.enable config.services.kanata-switcher.gnomeExtension.package;
      systemd.user.services = lib.mapAttrs' (
        keyboardName: _:
        lib.nameValuePair "kanata-switcher-${keyboardName}" {
          unitConfig.ConditionUser = owner;
        }
      ) switcherKeyboards;

      # Workaround: restart kanata-switcher for all active users during activation
      # Always restart on every switch (hash-based detection doesn't work reliably)
      system.activationScripts.restart-kanata-switcher = ''
        echo "Restarting kanata-switcher for all logged-in users..."
        for uid in $(${pkgs.systemd}/bin/loginctl list-users --no-legend 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $1}'); do
          user=$(${pkgs.systemd}/bin/loginctl show-user "$uid" -p Name --value 2>/dev/null || true)
          if [ -n "$user" ] && [ "$user" = "${owner}" ] && [ -d "/run/user/$uid" ]; then
            echo "  Restarting kanata-switcher units for $user (uid $uid)"
            ${pkgs.util-linux}/bin/runuser -u "$user" -- \
              env XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
              ${pkgs.systemd}/bin/systemctl --user restart ${lib.concatStringsSep " " switcherServiceNames} 2>&1 || true
          fi
        done
      '';
    })
  ];
}
