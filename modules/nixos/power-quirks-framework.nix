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

    psr.enable = lib.mkEnableOption ''
      amdgpu PSR/PSR-SU/PSR2 disable (amdgpu.dcdebugmask=0x610).
      Panel Self Refresh causes s2idle failures on Strix Point.
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

    ath12k-suspend.enable = lib.mkEnableOption ''
      ath12k WiFi module unload before suspend.
      WCN7850 firmware fails to enter power save cleanly, causing s2idle entry failures
      (constant "failed to pull fw stats: -71" EPROTO errors).
      Needed on kernel 6.18+
    '';

    disable-thunderbolt-wakeup.enable = lib.mkEnableOption ''
      Thunderbolt NHI wakeup source disable.
      NHI0/NHI1 generate spurious interrupts that prevent s0ix entry on AMD platforms.
      Needed on kernel 6.18+
    '';

    mt7925e-suspend.enable = lib.mkEnableOption ''
      MT7925e WiFi module unload before suspend.
      MT7925e driver doesn't handle power management properly on some firmware versions
    '';
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # --- Kernel parameters ---

    (lib.mkIf cfg.cwsr.enable {
      boot.kernelParams = [ "amdgpu.cwsr_enable=0" ];
    })

    (lib.mkIf cfg.psr.enable {
      boot.kernelParams = [ "amdgpu.dcdebugmask=0x610" ];
    })

    (lib.mkIf cfg.iommu-fullflush.enable {
      boot.kernelParams = [ "amd_iommu=fullflush" ];
    })

    (lib.mkIf cfg.nvidia-gpio-wakeup.enable {
      boot.kernelParams = [ "gpiolib_acpi.ignore_interrupt=AMDI0030:00@16" ];
    })

    # --- Systemd services ---

    (lib.mkIf cfg.ath12k-suspend.enable {
      systemd.services.ath12k-suspend = {
        description = "Unload ath12k WiFi before suspend";
        before = [ "sleep.target" ];
        wantedBy = [ "sleep.target" ];
        unitConfig.StopWhenUnneeded = true;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "ath12k-unload" ''
            set -euo pipefail
            if ${pkgs.kmod}/bin/lsmod | ${pkgs.gnugrep}/bin/grep -wq ath12k; then
              ${pkgs.util-linux}/bin/logger -p user.info "Unloading ath12k before suspend"
              ${pkgs.kmod}/bin/modprobe -r ath12k_pci ath12k 2>/dev/null || true
            fi
          '';
          ExecStop = pkgs.writeShellScript "ath12k-reload" ''
            set -euo pipefail
            if ! ${pkgs.kmod}/bin/lsmod | ${pkgs.gnugrep}/bin/grep -wq ath12k; then
              ${pkgs.util-linux}/bin/logger -p user.info "Reloading ath12k after resume"
              sleep 1
              ${pkgs.kmod}/bin/modprobe ath12k_pci 2>/dev/null || true
              sleep 3
              ${pkgs.networkmanager}/bin/nmcli device set wlan0 managed yes 2>/dev/null || true
            fi
          '';
        };
      };
    })

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

    (lib.mkIf cfg.mt7925e-suspend.enable {
      systemd.services.mt7925e-suspend = {
        description = "Unload MT7925e WiFi before suspend";
        before = [ "sleep.target" ];
        wantedBy = [ "sleep.target" ];
        unitConfig.StopWhenUnneeded = true;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.kmod}/bin/modprobe -r mt7925e";
          ExecStop = pkgs.writeShellScript "mt7925e-resume" ''
            set -euo pipefail
            sleep 1
            for i in 1 2 3; do
              if ${pkgs.kmod}/bin/modprobe mt7925e 2>/dev/null; then
                ${pkgs.util-linux}/bin/logger -p user.info "mt7925e loaded on attempt $i"
                break
              fi
              ${pkgs.util-linux}/bin/logger -p user.warning "mt7925e modprobe attempt $i failed, retrying..."
              sleep 1
            done
            for i in $(seq 1 10); do
              if ${pkgs.iproute2}/bin/ip link show wlan0 &>/dev/null; then
                ${pkgs.util-linux}/bin/logger -p user.info "wlan0 interface is up"
                break
              fi
              sleep 0.5
            done
            if ${pkgs.iproute2}/bin/ip link show wlan0 &>/dev/null; then
              sleep 1
              ${pkgs.networkmanager}/bin/nmcli device set wlan0 managed yes 2>/dev/null || true
              ${pkgs.networkmanager}/bin/nmcli device reapply wlan0 2>/dev/null || true
            else
              ${pkgs.util-linux}/bin/logger -p user.warning "wlan0 did not appear after resume"
            fi
          '';
        };
      };
    })
  ]);
}
