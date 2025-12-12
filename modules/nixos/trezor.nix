{ pkgs, lib, config, ... }: {
  options = {
    smind.hw.trezor.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Trezor hardware wallet support";
    };
  };

  config = lib.mkIf config.smind.hw.trezor.enable {
    services.udev = {
      packages = with pkgs; [ trezor-udev-rules ];
    };

    environment.systemPackages = with pkgs; [
      trezor-suite
      trezorctl
    ];

    services.trezord.enable = true;
  };

}
