{ config, lib, pkgs, ... }:

{
  options = {
    smind.hm.apps.prusa-3d-printing.enable = lib.mkEnableOption "3D model design and printing software (Prusa specific)";
  };

  config = lib.mkIf config.smind.hm.apps.prusa-3d-printing.enable {
    home.packages = with pkgs; [
      # Slicers
      prusa-slicer
      orca-slicer

      # CAD / Design
      freecad
      openscad
      blender
      solvespace
      dune3d

      # Mesh repair and manipulation
      meshlab
    ];
  };
}
