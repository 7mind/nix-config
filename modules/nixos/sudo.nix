{ config, lib, ... }:

{
  options = {
    smind.security.sudo.wheel-permissive-rules = lib.mkEnableOption "passwordless access to nix and systemd commands for wheel group";
    smind.security.sudo.wheel-passwordless = lib.mkEnableOption "passwordless sudo wheel group";
  };

  config = {
    security.sudo.extraRules =
      let
        profile = "/etc/profiles/per-user/*/bin/journalctl";
        global = "/run/current-system/sw/bin";
        binaries = [
          "/nix/var/nix/profiles/system/bin/switch-to-configuration"
          "${global}/nixos-rebuild"
          "${global}/nix"
          "${global}/nix-env"
          "${global}/pkill"
          "${profile}/systemctl"
          "${profile}/journalctl"
        ];
      in

      [
        (lib.mkIf
          config.smind.security.sudo.wheel-permissive-rules
          {
            groups = [ "wheel" ];
            commands = map
              (b: {
                command = b;
                options = [ "NOPASSWD" ];
              })
              binaries;
          }
        )

        (lib.mkIf
          config.smind.security.sudo.wheel-passwordless
          {
            groups = [ "wheel" ];
            commands = map
              (b: {
                command = "ALL";
                options = [ "NOPASSWD" ];
              })
              binaries;
          }
        )
      ];
  };
}
