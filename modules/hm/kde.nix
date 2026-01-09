{ config, lib, outerConfig, cfg-meta, ... }:

# This module configures KDE PowerDevil settings based on system-level options.
# Only applies on Linux where plasma-manager is available.

let
  cfg = config.smind.hm.desktop.kde;
  kdeEnabled = outerConfig.smind.desktop.kde.enable or false;
  isLaptop = outerConfig.smind.isLaptop or false;
in
{
  options.smind.hm.desktop.kde.auto-suspend.enable = lib.mkOption {
    type = lib.types.bool;
    default = isLaptop;
    description = "Enable automatic suspend on idle (typically for laptops)";
  };

  # Only define plasma options on Linux where plasma-manager exists
  # Use optionalAttrs for platform check (evaluated at load time)
  # Use mkIf for config-dependent conditions (evaluated at merge time)
  config = lib.optionalAttrs cfg-meta.isLinux (
    lib.mkIf (kdeEnabled && !cfg.auto-suspend.enable) {
      programs.plasma.powerdevil.AC.autoSuspend.action = "nothing";
    }
  );
}
