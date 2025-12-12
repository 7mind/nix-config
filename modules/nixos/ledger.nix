{ pkgs, lib, config, ... }: {
  options = {
    smind.hw.ledger.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Ledger hardware wallet support";
    };
  };

  config = lib.mkIf config.smind.hw.ledger.enable {
    services.udev = {
      packages = with pkgs; [ ledger-udev-rules ];
    };

    environment.systemPackages = with pkgs; [
      ledger-live-desktop
    ];

    hardware = {
      ledger.enable = true;
    };
  };

}
