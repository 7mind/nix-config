{ config, lib, pkgs, utils, ... }:
let
  homes = lib.mapAttrs' (name: home: lib.nameValuePair home.home.username {
    inherit (home.home) activationPackage path;
    inherit (config.users.users.${name}) group packages;
  }) config.home-manager.users;
  profileRoot = "/nix/var/nix/profiles/smind-home";
  profilePath = username: "${profileRoot}/${username}/generation";
  requestRoot = "/run/smind-home-manager";
  profileCommand = lib.getExe (pkgs.callPackage ../../pkg/home-manager-switch { nix = config.nix.package; });
in
{
  options.environment.etc = lib.mkOption {
    apply = entries: if !config.smind.home-manager.enable then entries else
      entries // lib.concatMapAttrs (username: home:
        let
          name = "profiles/per-user/${username}";
          systemName = "profiles/per-user-system/${username}";
          original = entries.${name};
        in {
          ${name} = original // { source = "${profilePath username}/home-path"; };
          ${systemName} = original // {
            target = systemName;
            source = original.source.override { paths = lib.remove home.path home.packages; };
          };
        }
      ) homes;
  };
  config = lib.mkIf config.smind.home-manager.enable {
    assertions = [
      { assertion = config.home-manager.useUserPackages && !config.home-manager.startAsUserService && !config.system.nixos-init.enable;
        message = "Persistent Home Manager requires external packages and NixOS system activation services"; }
    ];
    home-manager.sharedModules = [ ({ config, ... }: {
      options.home.activationPackage = lib.mkOption {
        apply = generation: pkgs.symlinkJoin {
          name = "hm-select-${config.home.username}";
          paths = [ generation ];
          passthru = { inherit generation; };
          postBuild = ''ln -sfn ${pkgs.writeShellScript "hm-select" "exec ${profileCommand} system ${profilePath config.home.username} ${requestRoot}/${config.home.username}"} "$out/activate"'';
        };
      };
    }) ];
    environment.etc = lib.mapAttrs' (username: _: lib.nameValuePair "smind/home-manager/${username}" {
      text = "${profilePath username}\n";
    }) homes;
    environment.profiles = [ "/etc/profiles/per-user-system/$USER" ];
    system.activationScripts.smind-home-manager = {
      deps = [ "users" "etc" ];
      text = ''
        ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root ${profileRoot} ${requestRoot}
        hm_system_generation="$(readlink -e "$systemConfig")"
        read -r hm_boot_id < /proc/sys/kernel/random/boot_id
      '' + lib.concatStrings (lib.mapAttrsToList (username: home: ''
        ${pkgs.coreutils}/bin/install -d -m 0755 -o ${lib.escapeShellArg username} -g ${lib.escapeShellArg home.group} ${lib.escapeShellArg "${profileRoot}/${username}"}
        request="$(mktemp "${requestRoot}/request.$hm_boot_id.XXXXXX")"
        printf '%s %s %s\n' "$hm_system_generation" "''${NIXOS_ACTION:-boot}" ${home.activationPackage.generation} > "$request"
        chmod 0644 "$request"
        ln -sfn "$request" ${lib.escapeShellArg "${requestRoot}/${username}"}
        [[ "''${NIXOS_ACTION:-boot}" == boot ]] || echo ${lib.escapeShellArg "home-manager-${utils.escapeSystemdPath username}.service"} >> /run/nixos/activation-restart-list
      '') homes);
    };
  };
}
