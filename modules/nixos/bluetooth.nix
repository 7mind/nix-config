{ config, pkgs, lib, ... }: {
  options = {
    smind.hw.bluetooth.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Bluetooth support with blueman";
    };
  };

  config = lib.mkIf config.smind.hw.bluetooth.enable {

    services.blueman.enable = true;

    hardware.bluetooth = {
      enable = true;
      settings = { General = { Enable = "Source,Sink,Media,Socket"; }; };
    };

    system.activationScripts.rfkill-unblock-bluetooth = ''
      rfkill unblock bluetooth
    '';
  };
}
