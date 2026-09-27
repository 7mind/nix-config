{ outerConfig, lib, ... }:

{
  config = lib.mkIf outerConfig.smind.environment.fileManagers.mc.enable {
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
