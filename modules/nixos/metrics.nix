{ config, lib, ... }:

{
  options = {
    smind.metrics.prometheus.exporters.generic.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.metrics.prometheus.exporters.generic.enable {
    services.prometheus.exporters = {
      systemd = {
        enable = true;
        openFirewall = true;
        port = 9558;
      };
      process = {
        port = 9256;
        openFirewall = true;
        enable = true;
      };
      node = {
        port = 9100;
        openFirewall = true;
        enable = true;
      };
    };
  };
}
