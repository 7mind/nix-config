{ config, lib, pkgs, cfg-meta, cfg-flakes, ... }:

{
  options = {
    smind.fonts.apple.enable = lib.mkEnableOption "Apple fonts (SF Pro, Menlo)";
  };

  config = lib.mkIf config.smind.fonts.apple.enable {
    fonts = {
      fontDir.enable = true;
      packages = with pkgs; [
        # original apple fonts
        menlo
        nix-apple-fonts
      ];
    };
  };
}
