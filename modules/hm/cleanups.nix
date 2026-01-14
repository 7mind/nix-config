{ config, lib, ... }:

{
  options = {
    smind.hm.cleanups.enable = lib.mkEnableOption "automatic cleanup of old profiles and mimeapps.list";
  };

  config = lib.mkIf config.smind.hm.cleanups.enable {
    home.activation.drop-mimeapps-list = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      echo >&2 "Removing ~/.config/mimeapps.list (it must be configured in nix)..."
      rm -f ${config.home.homeDirectory}/.config/mimeapps.list
    '';

    home.activation.hm-cleanup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      echo >&2 "Removing old profiles..."
      [[ "$USER" != "root" ]] && nix-env --profile ~/.local/state/nix/profiles/profile --delete-generations +5
      [[ "$USER" != "root" ]] && nix-env --profile ~/.local/state/nix/profiles/home-manager --delete-generations +5
    '';
  };
}
