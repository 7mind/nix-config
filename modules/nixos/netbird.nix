{ config, lib, ... }:

let
  cfg = config.smind.net.netbird;
in
{
  options.smind.net.netbird.enable = lib.mkEnableOption "NetBird client service" // {
    default = config.smind.isDesktop;
    defaultText = lib.literalExpression "config.smind.isDesktop";
  };

  config = lib.mkIf cfg.enable {
    services.netbird = {
      enable = true;
      ui.enable = lib.mkDefault config.smind.isDesktop;
    };

    systemd.network.wait-online.ignoredInterfaces = [
      config.services.netbird.clients.default.interface
    ];
  };
}
