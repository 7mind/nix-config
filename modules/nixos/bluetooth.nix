{ config, pkgs, lib, ... }:
let
  cfg = config.smind.hw.bluetooth;
in
{
  options = {
    smind.hw.bluetooth.enable = lib.mkEnableOption "Bluetooth support";
    smind.hw.bluetooth.blueman.enable = lib.mkEnableOption "blueman" // { default = true; };
  };

  config = lib.mkIf cfg.enable {

    services.blueman.enable = cfg.blueman.enable;

    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings = {
        General = {
          Enable = "Source,Sink,Media,Socket";
          Experimental = true;
          FastConnectable = true;
        };
        Policy = {
          AutoEnable = true;
        };
      };
    };

    system.activationScripts.rfkill-unblock-bluetooth = ''
      rfkill unblock bluetooth
    '';
  };
}
