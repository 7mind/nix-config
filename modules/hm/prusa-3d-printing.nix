{ config, lib, pkgs, ... }:

{
  options = {
    smind.hm.apps.prusa-3d-printing.enable = lib.mkEnableOption "3D model design and printing software (Prusa specific)";
  };

  config = lib.mkIf config.smind.hm.apps.prusa-3d-printing.enable {
    home.packages = with pkgs; [
      # Slicer
      prusa-slicer

      # CAD / Design
      freecad
      openscad
      blender

      # Mesh repair and manipulation
      meshlab
    ];
  };
}
