{ config, lib, pkgs, ... }:

{
  options = {
    smind.keyboard.super-remap.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.keyboard.super-remap.enable {
    services.keyd = {
      enable = true;
      keyboards.default = {
        ids = [ "*" ];
        settings = {
          main = { };

          "meta:M" = {
            #q = "macro(leftcontrol+q)";
            z = "macro(leftcontrol+z)";
            v = "macro(leftcontrol+v)";
            c = "macro(leftcontrol+c)";
            f = "macro(leftcontrol+f)";
          };

          "meta+shift" = { f = "macro(leftcontrol+leftshift+f)"; };
          #"control+alt+meta" = { "space" = "macro(scrolllock)"; };
        };
      };
    };
  };
}
