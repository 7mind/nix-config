{ config, lib, pkgs, ... }:

{
  options = {
    smind.vm.virt-manager.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };

    smind.vm.virt-manager.amd.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.vm.virt-manager.enable && config.smind.hw.cpu.isAmd;
      description = "";
    };
  };

  config = {
    assertions = [ ];

    virtualisation = lib.mkIf config.smind.vm.virt-manager.enable (
      let
        ovmf = (pkgs.OVMF.override {
          secureBoot = true;
          # csmSupport = false;
          httpSupport = true;
          tpmSupport = true;
        }).fd;
      in
      {
        spiceUSBRedirection.enable = true;

        libvirtd = {
          enable = true;
          onBoot = "ignore";
          qemu = {
            ovmf.packages = [ ovmf ];
            swtpm.enable = true;
          };
          allowedBridges = [
            config.smind.net.main-bridge
          ];
        };

      }
    );

    boot = lib.mkIf config.smind.vm.virt-manager.amd.enable {
      kernelParams = [
        "iommu=pt"
        "iommu_passthrough=1"
        "amd_iommu=pgtbl_v2"
        "amd_iommu_intr=vapic"
        # "pcie_aspm=off"
        "kvm.ignore_msrs=1"
        "vfio_iommu_type1.allow_unsafe_interrupts=1"
      ];

      kernelModules = [ "vfio_virqfd" "vfio_pci" "vfio_iommu_type1" "vfio" ];

      extraModprobeConfig =
        lib.concatStringsSep "\n" [
          "options kvm_amd nested=1"
          # "options vfio-pci ids=10de:2206,10de:1aef"
        ];
    };
  };
}
