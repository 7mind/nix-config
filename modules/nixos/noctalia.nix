{ config, lib, ... }:

let
  cfg = config.smind.desktop.noctalia;
in
{
  options.smind.desktop.noctalia = {
    enable = lib.mkEnableOption "Noctalia shell integration";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.networking.networkmanager.enable;
        message = "smind.desktop.noctalia.enable requires networking.networkmanager.enable = true";
      }
      {
        assertion = config.hardware.bluetooth.enable;
        message = "smind.desktop.noctalia.enable requires hardware.bluetooth.enable = true";
      }
      {
        assertion = config.services.upower.enable;
        message = "smind.desktop.noctalia.enable requires services.upower.enable = true";
      }
      {
        assertion = config.services.power-profiles-daemon.enable || config.services.tuned.enable;
        message = "smind.desktop.noctalia.enable requires either services.power-profiles-daemon.enable = true or services.tuned.enable = true";
      }
    ];

    services.noctalia-shell.enable = true;
    services.noctalia-shell.target = lib.mkIf config.smind.desktop.niri.enable (lib.mkDefault "niri.service");
  };
}
