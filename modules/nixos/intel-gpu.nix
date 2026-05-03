{ pkgs, lib, config, ... }:

let
  cfg = config.smind.hw.intel.gpu;

  # Script: bring SR-IOV VFs up. Iterates over all PCI devices bound to the
  # xe driver and writes numVfs to sriov_numvfs (clamped to sriov_totalvfs).
  # Discovery via the driver bus dir avoids hard-coding PCI BDFs.
  sriovUp = pkgs.writeShellScript "intel-gpu-sriov-up" ''
    set -euo pipefail
    target=${toString cfg.sriov.numVfs}
    found=0
    for pf in /sys/bus/pci/drivers/xe/[0-9a-f]*; do
      [[ -e "$pf/sriov_numvfs" ]] || continue
      [[ -e "$pf/sriov_totalvfs" ]] || continue
      found=1
      total=$(cat "$pf/sriov_totalvfs")
      n=$target
      if (( n > total )); then
        echo "intel-gpu-sriov: requested $n VFs exceeds totalvfs=$total on $(basename "$pf"), capping" >&2
        n=$total
      fi
      cur=$(cat "$pf/sriov_numvfs")
      if [[ "$cur" != "$n" ]]; then
        # Reset to 0 first if changing — kernel rejects non-zero->non-zero transitions.
        if [[ "$cur" != "0" ]]; then
          echo 0 > "$pf/sriov_numvfs"
        fi
        echo "$n" > "$pf/sriov_numvfs"
      fi
      echo "intel-gpu-sriov: $(basename "$pf") -> $n VFs (totalvfs=$total)"
    done
    if (( ! found )); then
      echo "intel-gpu-sriov: no Intel GPU PFs bound to xe driver yet" >&2
      exit 1
    fi
  '';

  sriovDown = pkgs.writeShellScript "intel-gpu-sriov-down" ''
    set -eu
    for pf in /sys/bus/pci/drivers/xe/[0-9a-f]*; do
      [[ -e "$pf/sriov_numvfs" ]] || continue
      echo 0 > "$pf/sriov_numvfs" || true
    done
  '';

in
{
  options.smind.hw.intel.gpu = {
    enable = lib.mkEnableOption "Intel discrete GPU support (Arc / Arc Pro Battlemage and newer)";

    driver = lib.mkOption {
      type = lib.types.enum [ "xe" "i915" ];
      default = "xe";
      description = ''
        Kernel driver to use for the Intel GPU. xe is the modern driver
        (Xe1 Alchemist and Xe2 Battlemage) and is required for SR-IOV.
        i915 is the legacy driver and only kept as an escape hatch.
      '';
    };

    compute.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = ''
        Expose the OpenCL / Level Zero / oneAPI compute stack
        (intel-compute-runtime, level-zero) — required for LLM inference
        and PyTorch (IPEX) workloads.
      '';
    };

    media.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable;
      description = ''
        Enable the VAAPI / oneVPL media stack (intel-media-driver, vpl-gpu-rt)
        for hardware video decode/encode (Jellyfin, ffmpeg, browsers).
      '';
    };

    sriov = {
      enable = lib.mkEnableOption ''
        SR-IOV preparation for the Intel GPU. Adds IOMMU kernel parameters
        and provisions VFs on boot. Requires the xe driver and host firmware
        with SR-IOV support enabled in BIOS/UEFI.
      '';

      numVfs = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = ''
          Number of SR-IOV virtual functions to create on each Intel GPU PF
          at boot. Clamped to the device's sriov_totalvfs. 0 disables VF
          creation while still keeping IOMMU + SR-IOV kernel support enabled.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.sriov.enable || cfg.driver == "xe";
          message = "smind.hw.intel.gpu.sriov requires smind.hw.intel.gpu.driver = \"xe\"; the i915 driver does not implement SR-IOV for Battlemage.";
        }
      ];

      # Prefer xe over i915 for the configured driver. force_probe with `*`
      # tells the chosen driver to claim every supported Intel GPU PCI ID,
      # and `!*` on the other driver prevents auto-binding races during boot.
      boot.kernelParams =
        (
          if cfg.driver == "xe" then [
            "i915.force_probe=!*"
            "xe.force_probe=*"
          ] else [
            "xe.force_probe=!*"
            "i915.force_probe=*"
          ]
        ) ++ [
          # Battlemage idles at ~40W instead of ~10-15W unless PCIe ASPM L1
          # substates are active. Server-board FADTs commonly mark ASPM as
          # unsupported, which makes the kernel disable the whole subsystem
          # before any policy applies — `pcie_aspm=force` overrides that and
          # `policy=powersupersave` then opts every link into the deepest
          # supported substate (kernel falls back per-link as needed).
          "pcie_aspm=force"
          "pcie_aspm.policy=powersupersave"
        ] ++ lib.optionals cfg.sriov.enable [
          "intel_iommu=on"
          "iommu=pt"
        ];

      boot.kernelModules = [ cfg.driver ];

      hardware.graphics = {
        enable = true;
        enable32Bit = true;
        extraPackages = lib.optionals cfg.compute.enable (with pkgs; [
          intel-compute-runtime
          level-zero
          ocl-icd
        ]) ++ lib.optionals cfg.media.enable (with pkgs; [
          intel-media-driver
          vpl-gpu-rt
          libvpl
        ]);
      };

      environment.systemPackages = with pkgs; [
        intel-gpu-tools
        libva-utils
        vulkan-tools
      ] ++ lib.optionals cfg.compute.enable [
        clinfo
        level-zero
      ];

      # Userspace tooling for IPEX/PyTorch finds Level Zero through
      # /run/opengl-driver/lib via NixOS' addOpenGLRunpath; no LD_LIBRARY_PATH
      # pollution needed here.
    }

    (lib.mkIf cfg.sriov.enable {
      # SR-IOV provisioning runs once on boot, after the xe driver has bound
      # to the PF. The udev settle ensures /sys/bus/pci/drivers/xe/* exists.
      systemd.services.intel-gpu-sriov = lib.mkIf (cfg.sriov.numVfs > 0) {
        description = "Provision Intel GPU SR-IOV virtual functions";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-modules-load.service" "systemd-udev-settle.service" ];
        wants = [ "systemd-udev-settle.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = sriovUp;
          ExecStop = sriovDown;
        };
      };
    })
  ]);
}
