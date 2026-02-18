{ config, lib, pkgs, ... }:

let
  mkDconfProfileService =
    { name
    , profile
    , matchSession
    ,
    }:
    lib.mkIf (profile != "user") {
      systemd.user.services.${name} =
        let
          setProfile = pkgs.writeShellScript "${name}-set" ''
            set -euo pipefail
            if ${matchSession}; then
              export DCONF_PROFILE=${lib.escapeShellArg profile}
              ${pkgs.dbus}/bin/dbus-update-activation-environment --systemd DCONF_PROFILE
              ${pkgs.systemd}/bin/systemctl --user import-environment DCONF_PROFILE
            fi
          '';
          unsetProfile = pkgs.writeShellScript "${name}-unset" ''
            set -euo pipefail
            ${pkgs.systemd}/bin/systemctl --user unset-environment DCONF_PROFILE
          '';
        in
        {
          description = "Set DCONF_PROFILE for ${name} session";
          before = [ "graphical-session.target" ];
          partOf = [ "graphical-session.target" ];
          wants = [ "graphical-session-pre.target" ];
          wantedBy = [ "graphical-session-pre.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${setProfile}";
            ExecStop = "${unsetProfile}";
          };
        };
    };
in
{
  config = lib.mkMerge [
    (lib.mkIf config.smind.desktop.gnome.enable (mkDconfProfileService {
      name = "smind-dconf-profile-gnome";
      profile = config.smind.desktop.gnome.dconf.profile;
      matchSession = '' [ -n "''${XDG_CURRENT_DESKTOP:-}" ] && printf "%s" "$XDG_CURRENT_DESKTOP" | ${pkgs.gnugrep}/bin/grep -qi GNOME '';
    }))
    (lib.mkIf config.smind.desktop.kde.enable (mkDconfProfileService {
      name = "smind-dconf-profile-kde";
      profile = config.smind.desktop.kde.dconf.profile;
      matchSession = '' [ "''${KDE_FULL_SESSION:-}" = "true" ] || { [ -n "''${XDG_CURRENT_DESKTOP:-}" ] && printf "%s" "$XDG_CURRENT_DESKTOP" | ${pkgs.gnugrep}/bin/grep -qi KDE; } '';
    }))
    (lib.mkIf config.smind.desktop.cosmic.enable (mkDconfProfileService {
      name = "smind-dconf-profile-cosmic";
      profile = config.smind.desktop.cosmic.dconf.profile;
      matchSession = '' [ -n "''${XDG_CURRENT_DESKTOP:-}" ] && printf "%s" "$XDG_CURRENT_DESKTOP" | ${pkgs.gnugrep}/bin/grep -qi COSMIC '';
    }))
  ];
}
