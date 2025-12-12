{ config, lib, ... }:

{
  options = {
    smind.ssh.safe.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable hardened SSH server (key-only, group-based access)";
    };
  };

  config = lib.mkIf config.smind.ssh.safe.enable {
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
  };
}
