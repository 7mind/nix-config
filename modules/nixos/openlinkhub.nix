{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.openlinkhub;
  package = pkgs.openlinkhub;
  provision = pkgs.writeShellScript "openlinkhub-provision" ''
    set -eu
    cd /var/lib/openlinkhub

    ${pkgs.coreutils}/bin/ln -sfnT ${package.assets.static} static
    ${pkgs.coreutils}/bin/ln -sfnT ${package.assets.web} web

    ${pkgs.coreutils}/bin/mkdir -p database
    ${pkgs.coreutils}/bin/cp -rn --no-preserve=mode,ownership ${package.assets.database}/. database/

    for name in config.json dashboard.json display.json; do
      if [ -f ${package.assets.root}/"$name" ] && [ ! -e "$name" ]; then
        ${pkgs.coreutils}/bin/cp --no-preserve=mode,ownership ${package.assets.root}/"$name" "$name"
      fi
    done

    ${pkgs.coreutils}/bin/printf '%s\n' ${lib.escapeShellArg package.version} > .package-version
  '';
in
{
  options.services.openlinkhub.enable = lib.mkEnableOption "OpenLinkHub device controller and WebUI";

  config = lib.mkIf cfg.enable {
    users.groups.openlinkhub = { };
    users.users.openlinkhub = {
      isSystemUser = true;
      group = "openlinkhub";
    };

    services.udev.packages = [ package ];

    systemd.services.openlinkhub = {
      description = "OpenLinkHub device controller and WebUI";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = "openlinkhub";
        Group = "openlinkhub";
        StateDirectory = "openlinkhub";
        WorkingDirectory = "/var/lib/openlinkhub";
        ExecStartPre = provision;
        ExecStart = "${package}/bin/OpenLinkHub";
        Restart = "on-failure";
      };
    };
  };
}
