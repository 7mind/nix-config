{ config, lib, ... }:

let
  cfg = config.smind.ssh;
in
{
  options = {
    smind.ssh.mode = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "permissive" "safe" ]);
      default = null;
      description = ''
        SSH server mode:
        - null: SSH not managed by this module
        - "permissive": SSH enabled with root login allowed (password auth enabled)
        - "safe": Hardened SSH (key-only auth, group-based access, mosh enabled)
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.mode == "permissive") {
      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = "yes";
        };
        openFirewall = true;
      };
    })

    (lib.mkIf (cfg.mode == "safe") {
      users.groups.ssh-users = { };

      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = lib.mkDefault "prohibit-password";
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          AllowUsers = [ "root" ];
        };
        extraConfig = ''
          Match group ssh-users
            AllowUsers *
        '';
        openFirewall = true;
      };

      programs.mosh = {
        enable = true;
        openFirewall = true;
      };
    })
  ];
}
