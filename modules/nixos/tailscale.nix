{ config, lib, pkgs, ... }:

{
  options = {
    smind.net.tailscale.enable = lib.mkEnableOption "tailscale service";
    smind.net.tailscale.gro-interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The interface to apply the UDP GRO fix to.";
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

    systemd.services.tailscale-gro-fix = lib.mkIf (config.smind.net.tailscale.gro-interface != null) {
      description = "Apply Tailscale UDP GRO fix";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.ethtool}/bin/ethtool -K ${config.smind.net.tailscale.gro-interface} rx-udp-gro-forwarding on rx-gro-list off";
        RemainAfterExit = true;
      };
    };
  };
}
