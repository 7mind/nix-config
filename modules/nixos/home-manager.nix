{ config, lib, pkgs, utils, ... }:
let
  homes = lib.mapAttrs' (name: home:
    lib.nameValuePair home.home.username {
      inherit (home.home) activationPackage;
      homePath = home.home.path;
      inherit (config.users.users.${name}) group packages;
    }
  ) config.home-manager.users;
  profileRoot = "/nix/var/nix/profiles/smind-home";
  profilePath = username: "${profileRoot}/${username}/generation";
  requestRoot = "/run/smind-home-manager";
  profileCommand = lib.getExe (pkgs.callPackage ../../pkg/home-manager-switch { nix = config.nix.package; });
  activate = pkgs.writeScript "hm-activate-selected" ''
    #!${pkgs.runtimeShell} -el
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$UID}"
    eval "$(${pkgs.systemd}/bin/systemctl --user show-environment 2>/dev/null |
      ${pkgs.gnused}/bin/sed -En '/^(DBUS_SESSION_BUS_ADDRESS|DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR)=/s/^/export /p')"
    ${profileCommand} system "$1" "$2"
    exec ${profileCommand} activate "$1"
  '';
in
{
  config = lib.mkIf config.smind.home-manager.enable {
    assertions = [
      { assertion = config.home-manager.useUserPackages;
        message = "Persistent Home Manager integration requires external package installation"; }
      { assertion = !config.home-manager.startAsUserService;
        message = "Persistent Home Manager integration requires system activation services"; }
      { assertion = !config.system.nixos-init.enable;
        message = "Persistent Home Manager integration requires NixOS activation scripts"; }
    ];

    environment.etc = lib.concatMapAttrs (username: home: {
      "smind/home-manager/${username}".text = "${profilePath username}\n";
      "profiles/per-user/${username}".source = lib.mkForce "${profilePath username}/home-path";
      "profiles/per-user-system/${username}".source = pkgs.buildEnv {
        name = "system-user-environment";
        paths = lib.remove home.homePath home.packages;
        inherit (config.environment) pathsToLink extraOutputsToInstall;
        inherit (config.system.path) ignoreCollisions postBuild;
      };
    }) homes;
    environment.profiles = [ "/etc/profiles/per-user-system/$USER" ];

    systemd.services = lib.mapAttrs' (username: home:
      lib.nameValuePair "home-manager-${utils.escapeSystemdPath username}" {
        serviceConfig.ExecStart = lib.mkForce "${activate} ${profilePath username} ${requestRoot}/${username}";
        restartTriggers = [ home.activationPackage ];
      }
    ) homes;

    system.activationScripts.smind-home-manager = {
      deps = [ "users" "etc" ];
      text = ''
        ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root ${profileRoot} ${requestRoot}
        hm_system_generation="$(readlink -e "$systemConfig")"
        read -r hm_boot_id < /proc/sys/kernel/random/boot_id
      '' + lib.concatStrings (lib.mapAttrsToList (username: home: ''
        ${pkgs.coreutils}/bin/install -d -m 0755 -o ${lib.escapeShellArg username} \
          -g ${lib.escapeShellArg home.group} ${lib.escapeShellArg "${profileRoot}/${username}"}
        request="$(mktemp "${requestRoot}/request.$hm_boot_id.XXXXXX")"
        printf '%s\n' "$hm_system_generation" "''${NIXOS_ACTION:-boot}" ${home.activationPackage} > "$request"
        chmod 0644 "$request"
        ln -sfn "$request" ${lib.escapeShellArg "${requestRoot}/${username}"}
        if [[ "''${NIXOS_ACTION:-boot}" != boot ]]; then
          echo ${lib.escapeShellArg "home-manager-${utils.escapeSystemdPath username}.service"} >> /run/nixos/activation-restart-list
        fi
      '') homes);
    };
  };
}
