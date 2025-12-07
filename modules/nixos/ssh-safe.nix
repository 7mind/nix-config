{ config, lib, ... }:

{
  options = {
    smind.ssh.safe = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.ssh.safe {
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
