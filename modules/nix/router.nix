{ config, lib, ... }:

{
  options = {
    smind.router.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable ipv4/ipv6 forwarding";
    };
  };

  config = lib.mkIf config.smind.router.enable {
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };

    networking.firewall.checkReversePath = "loose";
  };
}
