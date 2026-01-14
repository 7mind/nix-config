{ pkgs, lib, config, ... }: {
  options = {
    smind.hw.ledger.enable = lib.mkEnableOption "Ledger hardware wallet support";
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
