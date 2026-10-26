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
    # Restart each HM service when its generation changes via the declarative
    # unit-diff mechanism (X-Restart-Triggers), not /run/nixos/activation-
    # restart-list (deprecated, removed in NixOS 26.11). ExecStart already
    # embeds activationPackage, so this is belt-and-braces against the unit
    # text ceasing to embed it. Deliberately NOT preserved: a switch to an
    # identical toplevel no longer re-asserts the system-pinned generation
    # over a standalone switch-home change, and a failed HM service is no
    # longer retried by an unrelated system switch. To keep that total
    # rather than deferred, the request file below lives at a stable path:
    # an identical-toplevel activation rewrites identical content, so the
    # request marker in profile.sh still matches and a later manual service
    # restart does not consume a stale re-assertion either. A changed
    # toplevel is still detected via the system-generation marker (the HM
    # generation is an input to the toplevel, so it cannot change alone).
    systemd.services = lib.mapAttrs' (username: home: lib.nameValuePair "home-manager-${utils.escapeSystemdPath username}" {
      restartTriggers = [ home.activationPackage.generation ];
    }) homes;
    system.activationScripts.smind-home-manager = {
      deps = [ "users" "etc" ];
      text = ''
        ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root ${profileRoot} ${requestRoot}
        hm_system_generation="$(readlink -e "$systemConfig")"
      '' + lib.concatStrings (lib.mapAttrsToList (username: home: ''
        ${pkgs.coreutils}/bin/install -d -m 0755 -o ${lib.escapeShellArg username} -g ${lib.escapeShellArg home.group} ${lib.escapeShellArg "${profileRoot}/${username}"}
        request=${lib.escapeShellArg "${requestRoot}/${username}.request"}
        request_tmp="$(mktemp "${requestRoot}/.request.XXXXXX")"
        printf '%s %s %s\n' "$hm_system_generation" "''${NIXOS_ACTION:-boot}" ${home.activationPackage.generation} > "$request_tmp"
        chmod 0644 "$request_tmp"
        mv -f "$request_tmp" "$request"
        ln -sfn "$request" ${lib.escapeShellArg "${requestRoot}/${username}"}
      '') homes);
    };
  };
}
