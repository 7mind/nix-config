{ lib, config, ... }:
let
  cfg = config.smind.hw.qmk-keyboard;
in
{
  options.smind.hw.qmk-keyboard = {
    enable = lib.mkEnableOption "QMK/VIA keyboard support (udev rules for flashing and VIA configurator)";

    frameworkKeyboard = lib.mkEnableOption "Framework Laptop 16 keyboard module rules for VIA configurator";
  };

  config = lib.mkIf cfg.enable {
    hardware.keyboard.qmk.enable = true;

    services.udev.extraRules = lib.mkIf cfg.frameworkKeyboard ''
      # Framework Laptop 16 Keyboard Module - ANSI (32ac:0012)
      # uaccess tag grants access to logged-in users via ACLs
      SUBSYSTEM=="hidraw", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0012", MODE="0660", TAG+="uaccess"
      SUBSYSTEM=="usb", ATTRS{idVendor}=="32ac", ATTRS{idProduct}=="0012", MODE="0660", TAG+="uaccess"
    '';
  };
}
