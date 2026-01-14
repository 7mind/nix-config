{ config, lib, pkgs, ... }:

{
  options = {
    smind.environment.alien-filesystems.enable = lib.mkEnableOption "support for NTFS and other non-native filesystems";
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
