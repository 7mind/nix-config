{ config, lib, ... }:

{
  options = {
    smind.dev.adb.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.isDesktop or false;
      description = "Enable Android Debug Bridge (ADB) support";
    };

    smind.dev.adb.users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "pavel" ];
      description = "Users to add to adbusers group";
    };
  };

  config = lib.mkIf config.smind.dev.adb.enable {
    programs.adb.enable = true;

    users.users = lib.genAttrs config.smind.dev.adb.users (user: {
      extraGroups = [ "adbusers" ];
    });
  };
}
