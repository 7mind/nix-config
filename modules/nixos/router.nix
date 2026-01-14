{ config, lib, ... }:

{
  options = {
    smind.net.router.enable = lib.mkEnableOption "ipv4/ipv6 forwarding";
  };

  config = lib.mkIf config.smind.net.router.enable {
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };

    networking.firewall.checkReversePath = "loose";
  };
}
