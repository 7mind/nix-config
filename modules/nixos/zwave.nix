{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.zwave-js-ui;
in
{
  options = {
    smind.services.zwave-js-ui = {
      enable = lib.mkEnableOption "Z-Wave JS UI service";
      serialPort = lib.mkOption {
        type = lib.types.path;
        default = "/dev/ttyZWave";
        description = "The serial port for the Z-Wave controller.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.zwave-js-ui = {
      enable = true;
      serialPort = cfg.serialPort;
    };

    users.users.zwave-js-ui = {
      isSystemUser = true;
      group = "zwave-js-ui";
      extraGroups = [ "dialout" ];
    };

    users.groups.zwave-js-ui = {};

    # Open the default port in the firewall
    networking.firewall.allowedTCPPorts = [ 8091 3000 ]; # 3000 is the default Z-Wave JS server port
  };
}
