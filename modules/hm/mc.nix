{ config, lib, ... }:

{
  config = lib.mkIf config.smind.hm.globals.environment.fileManagers.mc.enable {
    programs.mc = {
      enable = true;
      settings = {
        "Midnight-Commander" = {
          skin = "dark";
        };
        "Layout" = {
          message_visible = 0;
          command_prompt = 0;
        };
      };
    };
  };
}
