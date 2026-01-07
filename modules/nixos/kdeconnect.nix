{ config, lib, pkgs, ... }:

let
  cfg = config.smind.kdeconnect;

  # Priority-based backend selection
  # Priority: KDE > GNOME
  selectedBackend =
    if cfg.backend != "auto" then cfg.backend
    else if config.smind.desktop.kde.enable then "kdeconnect-kde"
    else if config.smind.desktop.gnome.enable then "gsconnect"
    else "none";

  # Check if multiple desktops are enabled
  enabledDesktops = lib.filter (x: x != null) [
    (if config.smind.desktop.kde.enable then "KDE" else null)
    (if config.smind.desktop.gnome.enable then "GNOME" else null)
  ];
  hasMultipleDesktops = builtins.length enabledDesktops > 1;

in
{
  options.smind.kdeconnect = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.desktop.kde.enable || config.smind.desktop.gnome.enable;
      description = "Enable KDE Connect for phone/device integration";
    };

    backend = lib.mkOption {
      type = lib.types.enum [ "auto" "kdeconnect-kde" "gsconnect" ];
      default = "auto";
      description = ''
        KDE Connect backend to use.

        - auto: Automatically select based on priority: KDE > GNOME
        - kdeconnect-kde: Native KDE Connect application
        - gsconnect: GNOME Shell extension (GSConnect)

        Priority ensures deterministic selection regardless of module evaluation order.
      '';
    };

    selectedBackend = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      default = selectedBackend;
      description = "The selected KDE Connect backend (for use by DE modules)";
    };
  };

  config = lib.mkMerge [
    # Info message for multiple desktops
    {
      warnings = lib.optionals (cfg.enable && hasMultipleDesktops && cfg.backend == "auto") [
        ''
          Multiple desktop environments enabled: ${lib.concatStringsSep ", " enabledDesktops}
          Auto-selected KDE Connect backend: ${selectedBackend} (priority: KDE > GNOME)

          To override, set: smind.kdeconnect.backend = "kdeconnect-kde" | "gsconnect"
        ''
      ];

      assertions = [
        {
          assertion = !cfg.enable || selectedBackend != "auto";
          message = "KDE Connect backend could not be determined";
        }
      ];
    }

    # Enable KDE Connect (backend-specific config in DE modules)
    (lib.mkIf (cfg.enable && selectedBackend != "none") {
      programs.kdeconnect.enable = true;
    })

    (lib.mkIf (cfg.enable && selectedBackend == "gsconnect") {
      programs.kdeconnect.package = lib.mkForce pkgs.gnomeExtensions.gsconnect;
    })

    (lib.mkIf (cfg.enable && selectedBackend == "kde-connect-kde") {
      programs.kdeconnect.package = pkgs.kdePackages.kdeconnect-kde;
    })
  ];
}
