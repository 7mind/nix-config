{ config, lib, pkgs, ... }:

let
  cfg = config.smind.vm.virt-manager;
  isAmd = config.smind.hw.cpu.isAmd or false;
  mainBridge = config.smind.net.main-bridge or null;
in
{
  options.smind.vm.virt-manager = {
    enable = lib.mkEnableOption "libvirt with virt-manager and QEMU/KVM";

    iommu.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable && isAmd;
      description = "Enable IOMMU, VFIO and nested virtualization for GPU passthrough";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.virt-manager.enable = true;

    virtualisation = {
      spiceUSBRedirection.enable = true;

      libvirtd = {
        enable = true;
        onBoot = "ignore";
        qemu = {
          package = pkgs.qemu_kvm;
          runAsRoot = true;
          swtpm.enable = true;
        };
        allowedBridges = lib.optional (mainBridge != null) mainBridge;
      };
    };

    boot = lib.mkIf cfg.iommu.enable {
      kernelParams = [
        "iommu=pt"
        "kvm.ignore_msrs=1"
        "vfio_iommu_type1.allow_unsafe_interrupts=1"
      ] ++ lib.optionals isAmd [
        "amd_iommu=pgtbl_v2"
        "amd_iommu_intr=vapic"
      ];

      kernelModules = [
        "vfio_pci"
        "vfio_iommu_type1"
        "vfio"
      ];

      extraModprobeConfig = lib.optionalString isAmd "options kvm_amd nested=1";
    };
  };
}
