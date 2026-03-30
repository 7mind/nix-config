{ config, lib, pkgs, ... }:

let
  cfg = config.smind.power-management.framework-quirks;
in
{
  options.smind.power-management.framework-quirks = {
    enable = lib.mkEnableOption "Framework laptop power/suspend quirks";

    cwsr.enable = lib.mkEnableOption ''
      amdgpu CWSR disable (amdgpu.cwsr_enable=0).
      Prevents broken CWSR from causing MES ring saturation and hard freezes on Strix Point.
      Needed on kernel 6.18+
    '';

    iommu-fullflush.enable = lib.mkEnableOption ''
      AMD IOMMU full flush (amd_iommu=fullflush).
      Prevents IOMMU-related suspend failures with NVMe on AMD platforms.
      Needed on kernel 6.18+
    '';

    nvidia-gpio-wakeup.enable = lib.mkEnableOption ''
      NVIDIA dGPU GPIO wakeup interrupt ignore (gpiolib_acpi.ignore_interrupt=AMDI0030:00@16).
      Prevents dGPU GPIO interrupt from blocking s2idle entry on AMD+NVIDIA hybrid laptops.
      https://forums.developer.nvidia.com/t/590-6-18-suspend-immediately-interrupted-by-dgpu-on-amd-nvidia-laptops/357805
    '';

    disable-thunderbolt-wakeup.enable = lib.mkEnableOption ''
      Thunderbolt NHI wakeup source disable.
      NHI0/NHI1 generate spurious interrupts that prevent s0ix entry on AMD platforms.
      Needed on kernel 6.18+
    '';
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # --- Kernel parameters ---

    (lib.mkIf cfg.cwsr.enable {
      boot.kernelParams = [ "amdgpu.cwsr_enable=0" ];
    })

    (lib.mkIf cfg.iommu-fullflush.enable {
      boot.kernelParams = [ "amd_iommu=fullflush" ];
    })

    (lib.mkIf cfg.nvidia-gpio-wakeup.enable {
      boot.kernelParams = [ "gpiolib_acpi.ignore_interrupt=AMDI0030:00@16" ];
    })

    # --- Systemd services ---

    (lib.mkIf cfg.disable-thunderbolt-wakeup.enable {
      systemd.services.disable-thunderbolt-wakeup = {
        description = "Disable Thunderbolt NHI wakeup for s2idle";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "disable-nhi-wakeup" ''
            set -euo pipefail
            for dev in NHI0 NHI1; do
              if ${pkgs.gnugrep}/bin/grep -q "$dev.*enabled" /proc/acpi/wakeup; then
                echo "$dev" > /proc/acpi/wakeup
                ${pkgs.util-linux}/bin/logger -p user.info "Disabled ACPI wakeup for $dev"
              fi
            done
          '';
        };
      };
    })

  ]);
}
