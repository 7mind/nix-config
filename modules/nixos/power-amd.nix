{ config, lib, pkgs, ... }:

{
  options = {
    smind.power-management.desktop.amd.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.power-management.enable && config.smind.hw.cpu.isAmd;
      description = "Enable AMD-specific power management (amd_pstate)";
    };
  };

  config =
    (lib.mkIf config.smind.power-management.desktop.amd.enable {
      boot = {
        kernelParams = [
          # "msr.allow_writes=on"
        ];
      };
      powerManagement = {
        # amd-pstate always keeps governor as "powersave"
        cpuFreqGovernor = "powersave";
      };

      services.cpupower-gui.enable = true;

      services.auto-epp = {
        enable = true;
        settings = {
          Settings.epp_state_for_BAT = "power";
          Settings.epp_state_for_AC = "balance_performance";
        };
      };


      environment.systemPackages = with pkgs; [
        cpupower-gui
      ];
    });
}
