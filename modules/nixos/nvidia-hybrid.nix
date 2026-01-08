{ config, lib, pkgs, ... }:

let
  cfg = config.smind.hw.nvidia;
  cfgSpec = config.smind.hw.nvidia.specialisation;

  # Script to unbind GPU from nvidia and bind to vfio-pci for VM passthrough
  gpuBindVfio = pkgs.writeShellScriptBin "gpu-bind-vfio" ''
    set -euo pipefail

    if [[ $EUID -ne 0 ]]; then
      echo "This script must be run as root" >&2
      exit 1
    fi

    GPU_PCI="${cfg.pciId}"
    GPU_AUDIO_PCI="${cfg.audioPciId}"
    VENDOR_DEVICE="${cfg.vendorDeviceId}"
    AUDIO_VENDOR_DEVICE="${cfg.audioVendorDeviceId}"

    echo "Unbinding NVIDIA GPU from nvidia driver..."

    # Unload nvidia modules
    modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true

    # Unbind from nvidia driver
    if [[ -e "/sys/bus/pci/devices/$GPU_PCI/driver" ]]; then
      echo "$GPU_PCI" > /sys/bus/pci/devices/$GPU_PCI/driver/unbind 2>/dev/null || true
    fi
    if [[ -n "$GPU_AUDIO_PCI" ]] && [[ -e "/sys/bus/pci/devices/$GPU_AUDIO_PCI/driver" ]]; then
      echo "$GPU_AUDIO_PCI" > /sys/bus/pci/devices/$GPU_AUDIO_PCI/driver/unbind 2>/dev/null || true
    fi

    # Bind to vfio-pci
    modprobe vfio-pci

    echo "$VENDOR_DEVICE" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
    if [[ -n "$AUDIO_VENDOR_DEVICE" ]]; then
      echo "$AUDIO_VENDOR_DEVICE" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
    fi

    echo "GPU bound to vfio-pci. Ready for VM passthrough."
  '';

  # Script to unbind GPU from vfio-pci and rebind to nvidia for host use
  gpuBindNvidia = pkgs.writeShellScriptBin "gpu-bind-nvidia" ''
    set -euo pipefail

    if [[ $EUID -ne 0 ]]; then
      echo "This script must be run as root" >&2
      exit 1
    fi

    GPU_PCI="${cfg.pciId}"
    GPU_AUDIO_PCI="${cfg.audioPciId}"
    VENDOR_DEVICE="${cfg.vendorDeviceId}"
    AUDIO_VENDOR_DEVICE="${cfg.audioVendorDeviceId}"

    echo "Unbinding GPU from vfio-pci..."

    # Remove from vfio-pci
    echo "$VENDOR_DEVICE" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
    if [[ -n "$AUDIO_VENDOR_DEVICE" ]]; then
      echo "$AUDIO_VENDOR_DEVICE" > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
    fi

    # Unbind from vfio-pci
    if [[ -e "/sys/bus/pci/devices/$GPU_PCI/driver" ]]; then
      echo "$GPU_PCI" > /sys/bus/pci/devices/$GPU_PCI/driver/unbind 2>/dev/null || true
    fi
    if [[ -n "$GPU_AUDIO_PCI" ]] && [[ -e "/sys/bus/pci/devices/$GPU_AUDIO_PCI/driver" ]]; then
      echo "$GPU_AUDIO_PCI" > /sys/bus/pci/devices/$GPU_AUDIO_PCI/driver/unbind 2>/dev/null || true
    fi

    # Rescan PCI bus
    echo 1 > /sys/bus/pci/rescan

    # Load nvidia modules
    modprobe nvidia
    modprobe nvidia_modeset
    modprobe nvidia_drm
    modprobe nvidia_uvm

    echo "GPU bound to nvidia driver. Ready for host use."
  '';

in
{
  options.smind.hw.nvidia = {
    enable = lib.mkEnableOption "NVIDIA hybrid graphics with PRIME offload";

    specialisation = {
      enable = lib.mkEnableOption "boot menu entries for with/without NVIDIA GPU";

      defaultWithGpu = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          If true: default boot has NVIDIA, specialisation "no-nvidia" without.
          If false: default boot without NVIDIA, specialisation "nvidia" with GPU.
        '';
      };
    };

    pciId = lib.mkOption {
      type = lib.types.str;
      example = "0000:c1:00.0";
      description = "PCI bus ID of NVIDIA GPU (from lspci -D)";
    };

    audioPciId = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "0000:c1:00.1";
      description = "PCI bus ID of NVIDIA GPU audio device (usually .1 of GPU)";
    };

    vendorDeviceId = lib.mkOption {
      type = lib.types.str;
      example = "10de 2900";
      description = "Vendor and device ID for GPU (from lspci -nn, e.g., '10de 2900' for RTX 5070)";
    };

    audioVendorDeviceId = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "10de 22bc";
      description = "Vendor and device ID for GPU audio device";
    };

    nvidiaBusId = lib.mkOption {
      type = lib.types.str;
      example = "PCI:193:0:0";
      description = "NVIDIA GPU bus ID for PRIME (decimal format: PCI:bus:device:function)";
    };

    amdgpuBusId = lib.mkOption {
      type = lib.types.str;
      example = "PCI:0:2:0";
      description = "AMD iGPU bus ID for PRIME (decimal format)";
    };

    open = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use NVIDIA open kernel modules (may not support all features on new GPUs)";
    };
    };

  config =
    let
      # NVIDIA configuration to apply when GPU is active
      nvidiaConfig = {
        services.xserver.videoDrivers = [ "nvidia" ];

        # CUDA support for containers (Podman/Docker)
        hardware.nvidia-container-toolkit.enable = true;
        hardware.nvidia-container-toolkit.suppressNvidiaDriverAssertion = true;

        hardware.graphics.enable = true;

        hardware.nvidia = {
          open = cfg.open;
          modesetting.enable = true;
          nvidiaSettings = true;

          powerManagement.enable = true;
          powerManagement.finegrained = true;

          prime = {
            offload = {
              enable = true;
              enableOffloadCmd = true;
            };
            amdgpuBusId = cfg.amdgpuBusId;
            nvidiaBusId = cfg.nvidiaBusId;
          };
        };

        boot.kernelModules = [ "vfio-pci" ];

        # Enable NVIDIA RTD3 (Runtime D3) power management
        # 0x02 = Fine-grained power management, allows GPU to power down when idle
        # NVreg_PreserveVideoMemoryAllocations=1 is REQUIRED for suspend/resume
        # NVreg_TemporaryFilePath sets where VRAM is saved during suspend
        boot.extraModprobeConfig = ''
          options nvidia NVreg_DynamicPowerManagement=0x02
          options nvidia NVreg_PreserveVideoMemoryAllocations=1
          options nvidia NVreg_TemporaryFilePath=/var/tmp
        '';

        # NVIDIA suspend/resume/hibernate services - required for proper power management
        systemd.services.nvidia-suspend.enable = true;
        systemd.services.nvidia-resume.enable = true;
        systemd.services.nvidia-hibernate.enable = true;

        environment.systemPackages = [
          gpuBindVfio
          gpuBindNvidia
          pkgs.libva-utils
        ];

        systemd.services.nvidia-persistenced.enable = false;

        # Force session to use AMD iGPU by default
        # This allows NVIDIA GPU to power down via RTD3 when not in use
        # Use nvidia-offload for explicit GPU workloads
        environment.sessionVariables = {
          # Default to Mesa/AMD for OpenGL
          __GLX_VENDOR_LIBRARY_NAME = "mesa";
          # Don't set VK_DRIVER_FILES - let Vulkan discover drivers automatically
          # nvidia-offload uses __VK_LAYER_NV_optimus to select NVIDIA for Vulkan
          # Ensure EGL uses Mesa
          __EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json";
        };
      };

      # Minimal config when GPU is not present (just AMD iGPU)
      noNvidiaConfig = {
        services.xserver.videoDrivers = lib.mkForce [ "modesetting" ];
        hardware.nvidia.prime.offload.enable = lib.mkForce false;
        hardware.nvidia.prime.sync.enable = lib.mkForce false;
        hardware.nvidia.powerManagement.enable = lib.mkForce false;
        hardware.nvidia.powerManagement.finegrained = lib.mkForce false;
        hardware.nvidia.modesetting.enable = lib.mkForce false;
      };

    in
    lib.mkIf cfg.enable (lib.mkMerge [
      # Without specialisation: just apply nvidia config directly
      (lib.mkIf (!cfgSpec.enable) nvidiaConfig)

      # With specialisation: default has GPU, "no-nvidia" specialisation removes it
      (lib.mkIf (cfgSpec.enable && cfgSpec.defaultWithGpu) (lib.mkMerge [
        nvidiaConfig
        {
          specialisation.no-nvidia = {
            inheritParentConfig = true;
            configuration = noNvidiaConfig;
          };
        }
      ]))

      # With specialisation: default has no GPU, "nvidia" specialisation adds it
      (lib.mkIf (cfgSpec.enable && !cfgSpec.defaultWithGpu) {
        hardware.graphics.enable = true;
        specialisation.nvidia = {
          inheritParentConfig = true;
          configuration = nvidiaConfig;
        };
      })
    ]);
}
