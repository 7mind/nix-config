{ config, lib, pkgs, cfg-meta, ... }:

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

    ] ++ (if (cfg-meta.isLinux) then with pkgs; [
      # https://github.com/NixOS/nixpkgs/issues/413845
      unityhub
    ] else [ ]);

  };
}

