{ config, lib, pkgs, ... }:
let
  cfg = config.smind.hw.prusa-3d-printing;
in
{
  options.smind.hw.prusa-3d-printing = {
    enable = lib.mkEnableOption "3D printing hardware support and udev rules (Prusa specific)";

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "pavel" ];
      description = "Users to add to the dialout group for serial device access";
    };
  };

  config = lib.mkIf cfg.enable {
    # Prusa research USB serial devices
    services.udev.extraRules = ''
      # Original Prusa i3 MK2/MK2S/MK2.5
      SUBSYSTEM=="tty", ATTRS{idVendor}=="2c99", ATTRS{idProduct}=="0001", MODE="0660", GROUP="dialout", TAG+="uaccess"
      # Original Prusa i3 MK3/MK3S/MK3S+
      SUBSYSTEM=="tty", ATTRS{idVendor}=="2c99", ATTRS{idProduct}=="0002", MODE="0660", GROUP="dialout", TAG+="uaccess"
      # Original Prusa i3 MK4
      SUBSYSTEM=="tty", ATTRS{idVendor}=="2c99", ATTRS{idProduct}=="000c", MODE="0660", GROUP="dialout", TAG+="uaccess"
      # Original Prusa XL
      SUBSYSTEM=="tty", ATTRS{idVendor}=="2c99", ATTRS{idProduct}=="000d", MODE="0660", GROUP="dialout", TAG+="uaccess"
      # Original Prusa MINI/MINI+
      SUBSYSTEM=="tty", ATTRS{idVendor}=="2c99", ATTRS{idProduct}=="000e", MODE="0660", GROUP="dialout", TAG+="uaccess"
    '';

    users.users = lib.genAttrs cfg.users (_: {
      extraGroups = [ "dialout" ];
    });

    # Prusa-slicer package often provides its own rules if we include it in services.udev.packages
    # but we will put it in the HM module for user apps.
    # However, if it provides rules, we can add it here too.
    # services.udev.packages = [ pkgs.prusa-slicer ];
  };
}
