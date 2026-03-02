{ lib, pkgs, cfg-meta, outerConfig, ... }:

let
  niriEnabled = outerConfig.smind.desktop.niri.enable;
  defaultNiriConfigModule = import "${cfg-meta.inputs.niri}/default-config.kdl.nix" cfg-meta.inputs;
  inherit (cfg-meta.inputs.niri.lib.kdl) node plain leaf;
  scaledOutputNames = [
    "DP-1"
    "DP-2"
    "DP-3"
    "DP-4"
    "HDMI-A-1"
    "HDMI-A-2"
    "HDMI-A-3"
    "HDMI-A-4"
  ];
in
lib.optionalAttrs cfg-meta.isLinux {
  imports = [ defaultNiriConfigModule ];

  config = lib.mkMerge [
    (lib.mkIf niriEnabled {
      programs.niri.package = pkgs.niri;
      programs.niri.config = lib.mkAfter ((map (outputName: node "output" outputName [ (leaf "scale" 1.8) ]) scaledOutputNames) ++ [
        (plain "window-rule" [ (leaf "open-floating" true) ])
        (plain "xwayland-satellite" [ (leaf "path" (lib.getExe pkgs.xwayland-satellite)) ])
      ]);
    })
    (lib.mkIf (!niriEnabled) {
      programs.niri.config = lib.mkForce null;
    })
  ];
}
