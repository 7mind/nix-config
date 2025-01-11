{ pkgs, lib, config, ... }: {
  options = {
    smind.hw.uhk-keyboard.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hw.uhk-keyboard.enable {
    services.udev = {
      packages = with pkgs; [ uhk-udev-rules ];
    };

    environment.systemPackages = with pkgs; [
      uhk-agent
    ];

    hardware = {
      keyboard.uhk.enable = true;
    };
  };

}
