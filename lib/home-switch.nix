{ pkgs, home }:
let
  profile = pkgs.callPackage ../pkg/home-manager-switch { };
  external = home.extendModules {
    modules = [ { submoduleSupport = { enable = true; externalPackageInstall = true; }; } ];
  };
in
pkgs.writeShellApplication {
  name = "switch-home";
  text = ''
    export HOME_MANAGER_BACKUP_EXT=hmbak
    ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''if [[ -e "$2" ]]; then
      if ! read -r profile < "$1/$(${pkgs.coreutils}/bin/id -un)"; then
        echo "Error: install persistent Home Manager integration with a full NixOS switch first" >&2
        exit 1
      fi
      exec ${pkgs.lib.getExe profile} switch "$profile" ${external.activationPackage}
    fi''}
    exec ${home.activationPackage}/activate
  '';
}
