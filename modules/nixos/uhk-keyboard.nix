{ pkgs, lib, config, ... }: {
  options = {
    smind.hw.uhk-keyboard.enable = lib.mkEnableOption "Ultimate Hacking Keyboard support";
  };

  config = lib.mkIf config.smind.hw.uhk-keyboard.enable {
    services.udev = {
      packages = with pkgs; [ uhk-udev-rules ];
    };

    # SmartMacroCopy store-write workaround removed: upstream
    # UltimateHackingKeyboard/agent#3024 (chmod -R +w around the doc copies)
    # landed in the packaged v11.0.0, so the substituteInPlace patch and the
    # launch wrapper are obsolete.
    environment.systemPackages = [
      pkgs.uhk-agent
    ];

    hardware = {
      keyboard.uhk.enable = true;
    };
  };

}
