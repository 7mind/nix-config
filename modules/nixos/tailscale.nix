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

    systemd.services.tailscale-operator = lib.mkIf (config.smind.host.owner != null) {
      description = "Set tailscale operator to ${config.smind.host.owner}";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.tailscale}/bin/tailscale set --operator=${config.smind.host.owner}";
        RemainAfterExit = true;
      };
    };

    systemd.network.wait-online.ignoredInterfaces = [ "tailscale0" ];

    # On laptops, we rely on Tailscale subnet routing to reach LAN hosts remotely,
    # so we must not override Tailscale's routing table with the main table.
    systemd.services.ip-rules = lib.mkIf (!config.smind.isLaptop) {
      description = "Always prefer LAN routes over tailscale";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        # TODO: other prefixes
        ExecStartPre = "-${pkgs.iproute2}/bin/ip rule del to 192.168.0.0/16 pref 5000 lookup main";
        ExecStart = "${pkgs.iproute2}/bin/ip rule add to 192.168.0.0/16 pref 5000 lookup main";
        ExecStop = "-${pkgs.iproute2}/bin/ip rule del to 192.168.0.0/16 pref 5000 lookup main";
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
