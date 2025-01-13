{ config, lib, pkgs, cfg-meta, cfg-flakes, ... }:

{
  options = {
    smind.fonts.apple.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
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
