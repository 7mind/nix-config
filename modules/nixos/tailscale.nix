{ config, lib, ... }:

{
  options = {
    smind.net.tailscale.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.net.tailscale.enable {
    services.tailscale = {
      enable = true;
      interfaceName = "tailscale0";
    };
    systemd.network.wait-online.ignoredInterfaces = [ "tailscale0" ];
  };
}
