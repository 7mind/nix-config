{ config, lib, pkgs, ... }:

{
  options = {
    smind.net.tailscale.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable tailscale service";
    };
    smind.net.tailscale.groInterface = lib.mkOption {
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

    services.networkd-dispatcher = lib.mkIf (config.smind.net.tailscale.groInterface != null) {
      enable = true;
      rules."50-tailscale-udp-gro" = {
        onState = [ "routable" ];
        script = ''
          #!/bin/sh
          # Tune UDP GRO for Tailscale on ${config.smind.net.tailscale.groInterface}
          ${lib.getExe pkgs.ethtool} -K ${config.smind.net.tailscale.groInterface} rx-udp-gro-forwarding on rx-gro-list off
        '';
      };
    };
  };
}
