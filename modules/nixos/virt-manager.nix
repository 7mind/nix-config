{ config, lib, pkgs, ... }:

let
  cfg = config.smind.vm.virt-manager;
  nvidiaCfg = config.smind.hw.nvidia;
  isAmd = config.smind.hw.cpu.isAmd or false;
  mainBridge = config.smind.net.main-bridge or null;

  # Libvirt QEMU hook for automatic GPU passthrough
  qemuHook = pkgs.writeShellScript "qemu-hook" ''
    VM_NAME="$1"
    OPERATION="$2"
    SUB_OPERATION="$3"

    # Check if this VM should trigger GPU passthrough
    case "$VM_NAME" in
      ${lib.concatStringsSep "|" cfg.gpuPassthrough.vmNames})
        ;;
      *)
        exit 0
        ;;
    esac

    GPU_PCI="${nvidiaCfg.pciId}"
    GPU_AUDIO_PCI="${nvidiaCfg.audioPciId}"
    VENDOR_DEVICE="${nvidiaCfg.vendorDeviceId}"
    AUDIO_VENDOR_DEVICE="${nvidiaCfg.audioVendorDeviceId}"

    bind_vfio() {
      echo "Binding GPU to vfio-pci for VM: $VM_NAME"

      # Unload nvidia modules
      modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true

      # Unbind from nvidia
      [ -e "/sys/bus/pci/devices/$GPU_PCI/driver" ] && \
        echo "$GPU_PCI" > /sys/bus/pci/devices/$GPU_PCI/driver/unbind 2>/dev/null || true
      [ -n "$GPU_AUDIO_PCI" ] && [ -e "/sys/bus/pci/devices/$GPU_AUDIO_PCI/driver" ] && \
        echo "$GPU_AUDIO_PCI" > /sys/bus/pci/devices/$GPU_AUDIO_PCI/driver/unbind 2>/dev/null || true

      # Bind to vfio-pci
      modprobe vfio-pci
      echo "$VENDOR_DEVICE" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
      [ -n "$AUDIO_VENDOR_DEVICE" ] && \
        echo "$AUDIO_VENDOR_DEVICE" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
    }

    bind_nvidia() {
      echo "Rebinding GPU to nvidia for host use after VM: $VM_NAME"

      # Remove from vfio-pci
      echo "$VENDOR_DEVICE" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
      [ -n "$AUDIO_VENDOR_DEVICE" ] && \
        echo "$AUDIO_VENDOR_DEVICE" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true

      # Unbind from vfio-pci
      [ -e "/sys/bus/pci/devices/$GPU_PCI/driver" ] && \
        echo "$GPU_PCI" > /sys/bus/pci/devices/$GPU_PCI/driver/unbind 2>/dev/null || true
      [ -n "$GPU_AUDIO_PCI" ] && [ -e "/sys/bus/pci/devices/$GPU_AUDIO_PCI/driver" ] && \
        echo "$GPU_AUDIO_PCI" > /sys/bus/pci/devices/$GPU_AUDIO_PCI/driver/unbind 2>/dev/null || true

      # Rescan and reload nvidia
      echo 1 > /sys/bus/pci/rescan
      modprobe nvidia
      modprobe nvidia_modeset
      modprobe nvidia_drm
      modprobe nvidia_uvm
    }

    case "$OPERATION/$SUB_OPERATION" in
      prepare/begin)
        bind_vfio
        ;;
      release/end)
        bind_nvidia
        ;;
    esac
  '';
in
{
  options.smind.vm.virt-manager = {
    enable = lib.mkEnableOption "libvirt with virt-manager and QEMU/KVM";

    iommu.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable && isAmd;
      description = "Enable IOMMU, VFIO and nested virtualization for GPU passthrough";
    };

    gpuPassthrough = {
      enable = lib.mkEnableOption "automatic GPU bind/unbind for VM passthrough";

      vmNames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "win11" "gaming" ];
        description = "VM names that should trigger automatic GPU passthrough";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
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
    }

    (lib.mkIf cfg.iommu.enable {
      boot = {
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
    })

    # Automatic GPU passthrough via libvirt hooks
    (lib.mkIf (cfg.gpuPassthrough.enable && cfg.gpuPassthrough.vmNames != [ ]) {
      assertions = [{
        assertion = nvidiaCfg.enable or false;
        message = "gpuPassthrough requires smind.hw.nvidia.enable = true";
      }];

      # Install the QEMU hook via tmpfiles (runs after filesystem is mounted)
      systemd.tmpfiles.rules = [
        "d /var/lib/libvirt/hooks 0755 root root -"
        "L+ /var/lib/libvirt/hooks/qemu - - - - ${qemuHook}"
      ];
    })
  ]);
}
