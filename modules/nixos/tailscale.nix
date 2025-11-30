{ config, lib, pkgs, ... }:

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
      extraUpFlags = [ "--accept-dns=false" ];
    };

    systemd.network.wait-online.ignoredInterfaces = [ "tailscale0" ];

    systemd.services.ip-rules = {
      description = "Always prefer LAN routes over tailscale";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        # TODO: other prefixes
        ExecStart = "${pkgs.iproute2}/bin/ip rule add to 192.168.0.0/16 pref 5000 lookup main";
        RemainAfterExit = true;
      };
    };
  };
}
