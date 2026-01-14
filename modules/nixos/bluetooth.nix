{ config, pkgs, lib, ... }: {
  options = {
    smind.hw.bluetooth.enable = lib.mkEnableOption "Bluetooth support with blueman";
  };

  config = lib.mkIf config.smind.hw.bluetooth.enable {

    services.blueman.enable = true;

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
