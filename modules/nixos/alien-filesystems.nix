{ config, lib, pkgs, ... }:

{
  options = {
    smind.environment.alien-filesystems.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable support for NTFS and other non-native filesystems";
    };
  };

  config = lib.mkIf config.smind.environment.alien-filesystems.enable {
    boot.supportedFilesystems = [
      # "apfs" # broken
      "ntfs"
    ];

    environment.systemPackages = with pkgs; [
      ntfs3g
    ];
  };
}
