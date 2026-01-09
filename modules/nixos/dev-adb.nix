{ config, lib, pkgs, ... }:

{
  options = {
    smind.dev.adb.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isDesktop;
      description = "Enable Android Debug Bridge (ADB) support";
    };
  };

  config = lib.mkIf config.smind.dev.adb.enable {
    # systemd 258+ handles uaccess rules automatically, just need the package
    environment.systemPackages = [ pkgs.android-tools ];
  };
}
