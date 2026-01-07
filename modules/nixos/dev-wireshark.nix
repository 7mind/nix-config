{ config, lib, pkgs, ... }:

{
  options = {
    smind.dev.wireshark.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isDesktop;
      description = "Enable Wireshark with USB monitoring support";
    };

    smind.dev.wireshark.users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "pavel" ];
      description = "Users to add to wireshark group";
    };
  };

  config = lib.mkIf config.smind.dev.wireshark.enable {
    programs.wireshark.enable = true;
    programs.wireshark.package = pkgs.wireshark;

    boot.kernelModules = [ "usbmon" ];

    users.users = lib.genAttrs config.smind.dev.wireshark.users (user: {
      extraGroups = [ "wireshark" ];
    });
  };
}
