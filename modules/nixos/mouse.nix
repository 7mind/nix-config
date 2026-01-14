{ config, lib, ... }:

{
  options.smind.desktop.mouse = {
    acceleration = lib.mkOption {
      type = lib.types.numbers.between (-1.0) 1.0;
      default = 0.0;
      example = 0.2;
      description = ''
        Mouse pointer acceleration/speed adjustment.
        Range: -1.0 (slowest) to 1.0 (fastest), with 0.0 being default speed.
        Maps to libinput pointer acceleration value.
      '';
    };

    accelProfile = lib.mkOption {
      type = lib.types.enum [ "default" "flat" "adaptive" ];
      default = "flat";
      example = "adaptive";
      description = ''
        Mouse acceleration profile:
        - "default": Use device default profile
        - "flat": Constant acceleration factor (1:1 movement, no curve)
        - "adaptive": Dynamic acceleration based on movement speed
      '';
    };

    naturalScroll = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable natural (inverted) scrolling for mouse wheel.";
    };
  };
}
