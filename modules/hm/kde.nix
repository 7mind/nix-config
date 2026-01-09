{ config, lib, outerConfig, ... }:

# This module configures KDE PowerDevil settings based on system-level options.

let
  cfg = config.smind.hm.desktop.kde;
  kdeEnabled = outerConfig.smind.desktop.kde.enable;
  isLaptop = outerConfig.smind.isLaptop;
in
{
  options.smind.hm.desktop.kde.auto-suspend.enable = lib.mkOption {
    type = lib.types.bool;
    default = isLaptop;
    description = "Enable automatic suspend on idle (typically for laptops)";
  };

  #config = lib.mkIf (kdeEnabled && !cfg.auto-suspend.enable) {
  #  programs.plasma.powerdevil.AC.autoSuspend.action = "nothing";
  #};
}
