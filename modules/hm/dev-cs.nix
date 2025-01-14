{ config, lib, pkgs, ... }:

{
  options = {
    smind.hm.dev.cs.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.dev.cs.enable {
    home.packages = with pkgs; [
      unityhub
    ];

  };
}

