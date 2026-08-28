{ config, lib, pkgs, ... }:

{
  options = {
    smind.hm.apps.prusa-3d-printing.enable = lib.mkEnableOption "3D model design and printing software (Prusa specific)";
  };

  config = lib.mkIf config.smind.hm.apps.prusa-3d-printing.enable {
    home.packages = with pkgs; [
      prusa-slicer
      orca-slicer

      freecad
      openscad-unstable
      blender
      solvespace
      dune3d

      meshlab
    ];
  };
}
