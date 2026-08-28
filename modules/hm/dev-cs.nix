{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.hm.dev.cs.enable = lib.mkEnableOption "C#/.NET development tools";
  };

  config = lib.mkIf config.smind.hm.dev.cs.enable {
    home.packages = with pkgs; [

    ] ++ (if (cfg-meta.isLinux) then with pkgs; [
      unityhub
    ] else [ ]);

  };
}

