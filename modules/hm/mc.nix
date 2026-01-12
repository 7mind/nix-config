{ config, pkgs, lib, ... }:

{
  options = {
    smind.hm.mc.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Midnight Commander with dark theme";
    };
  };

  config = lib.mkIf config.smind.hm.mc.enable {
    programs.mc = {
      enable = true;
      settings = {
        "Midnight-Commander" = {
          skin = "dark";
          show_hints = 0;
          command_prompt = 0;
        };
      };
    };
  };
}
