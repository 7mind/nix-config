{ config, lib, pkgs, ... }:

{
  options = {
    smind.fonts.msfonts.enable = lib.mkEnableOption "Microsoft fonts collection";
  };

  config = lib.mkIf config.smind.fonts.msfonts.enable {
    fonts = {
      fontDir.enable = true;
      packages = with pkgs; [
        corefonts
        vista-fonts
      ];
    };
  };
}
