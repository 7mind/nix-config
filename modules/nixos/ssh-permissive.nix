{ config, lib, ... }:

{
  options = {
    smind.ssh.permissive.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow root login";
    };
  };

  config = lib.mkIf config.smind.ssh.permissive.enable {
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "yes";
      };
      openFirewall = true;
    };
  };
}
