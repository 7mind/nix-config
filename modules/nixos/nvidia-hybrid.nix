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
    enable = lib.mkEnableOption "NVIDIA GPU support (proprietary driver, CUDA)";

    prime.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable PRIME offload between an integrated GPU and the NVIDIA
        dGPU. Required for laptops with iGPU + dGPU; should be false on
        desktops that have a discrete AMD/Intel GPU as the primary
        (PRIME is meaningless without a render offload chain) or on
        headless machines where NVIDIA is only used for compute.

        When false, the PRIME-specific bus IDs, VFIO passthrough
        scripts, RTD3 power management, and `nvidia-offload` wrapper
        are all skipped; the module installs only the proprietary
        driver, modesetting, and the container toolkit.
      '';
    };

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
      default = "";
      example = "0000:c1:00.0";
      description = "PCI bus ID of NVIDIA GPU (from lspci -D). Required when prime.enable.";
    };

    audioPciId = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "0000:c1:00.1";
      description = "PCI bus ID of NVIDIA GPU audio device (usually .1 of GPU)";
    };

    vendorDeviceId = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "10de 2900";
      description = "Vendor and device ID for GPU (from lspci -nn). Required when prime.enable.";
    };

    audioVendorDeviceId = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "10de 22bc";
      description = "Vendor and device ID for GPU audio device";
    };

    nvidiaBusId = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "PCI:193:0:0";
      description = "NVIDIA GPU bus ID for PRIME (decimal format: PCI:bus:device:function). Required when prime.enable.";
    };

    amdgpuBusId = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "PCI:0:2:0";
      description = "AMD iGPU bus ID for PRIME (decimal format). Required when prime.enable.";
    };

    open = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use NVIDIA open kernel modules (required for RTX 50 series Blackwell)";
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Override nvidia driver package (e.g., pkgs.linuxPackages.nvidiaPackages.beta)";
    };
  };

  config =
    let
      # NVIDIA configuration to apply when GPU is active
      nvidiaConfig = {
        assertions = [
          {
            assertion = !cfg.prime.enable
              || (cfg.nvidiaBusId != "" && cfg.amdgpuBusId != "");
            message = "smind.hw.nvidia.prime.enable requires both nvidiaBusId and amdgpuBusId.";
          }
        ];

        services.xserver.videoDrivers = [ "nvidia" ];

        # CUDA support for containers (Podman/Docker)
        hardware.nvidia-container-toolkit.enable = true;
        hardware.nvidia-container-toolkit.suppressNvidiaDriverAssertion = true;

        hardware.graphics.enable = true;
        hardware.graphics.extraPackages = [ pkgs.nvidia-vaapi-driver ];

        hardware.nvidia = {
          open = cfg.open;
          modesetting.enable = true;
          nvidiaSettings = true;

          # PRIME-only: runtime PM is safe only under offload where the dGPU
          # sleeps when idle; elsewhere it only adds wake latency.
          powerManagement.enable = cfg.prime.enable;
          powerManagement.finegrained = cfg.prime.enable;
        } // lib.optionalAttrs cfg.prime.enable {
          prime = {
            offload = {
              enable = true;
              # Disabled so we can replace it with our own `nvidia-offload`
              # below (pre-warms the dGPU; upstream script has no setup hook).
              enableOffloadCmd = false;
            };
            amdgpuBusId = cfg.amdgpuBusId;
            nvidiaBusId = cfg.nvidiaBusId;
          };
        } // lib.optionalAttrs (cfg.package != null) {
          package = cfg.package;
        };

        boot.kernelModules = lib.mkIf cfg.prime.enable [ "vfio-pci" ];

        # NVIDIA RTD3 (PRIME-only). 0x02 = fine-grained PM (power down when
        # idle); PreserveVideoMemoryAllocations=1 is REQUIRED for suspend/resume;
        # TemporaryFilePath is where VRAM is saved during suspend.
        boot.extraModprobeConfig = lib.mkIf cfg.prime.enable ''
          options nvidia NVreg_DynamicPowerManagement=0x02
          options nvidia NVreg_PreserveVideoMemoryAllocations=1
          options nvidia NVreg_TemporaryFilePath=/var/tmp
        '';

        # NVIDIA suspend/resume/hibernate handled by nixpkgs' hardware.nvidia:
        # - With kernelSuspendNotifier (driver 595+, open modules): kernel handles it
        # - Without: nixpkgs creates systemd services with nvidia-sleep.sh ExecStart
        systemd.services = lib.mkMerge [
          # With kernelSuspendNotifier, nixpkgs skips creating these services,
          # but stale systemd state from prior generations can persist across
          # nixos-rebuild switch. systemd 259 creates empty stubs for referenced-
          # but-missing units then rejects them (no ExecStart), blocking suspend.
          # Provide explicit no-op services as a safety net.
          (lib.mkIf config.hardware.nvidia.powerManagement.kernelSuspendNotifier (
            let
              noop = desc: {
                description = desc;
                serviceConfig = {
                  Type = "oneshot";
                  ExecStart = "${pkgs.coreutils}/bin/true";
                };
              };
            in {
              nvidia-suspend = noop "NVIDIA suspend (no-op, kernel handles via suspend notifier)";
              nvidia-hibernate = noop "NVIDIA hibernate (no-op, kernel handles via suspend notifier)";
              nvidia-resume = noop "NVIDIA resume (no-op, kernel handles via suspend notifier)";
            }
          ))
          { nvidia-persistenced.enable = false; }
        ];

        environment.systemPackages = [
          pkgs.libva-utils
        ] ++ lib.optionals cfg.prime.enable [
          gpuBindVfio
          gpuBindNvidia

          # Replacement for upstream `nvidia-offload` (enableOffloadCmd disabled
          # above). Same env vars as the upstream script
          # (nixpkgs/nixos/modules/hardware/video/nvidia.nix — verbatim copy as of
          # nixpkgs 24.x; sanity-check on bumps), plus an `nvidia-smi` pre-warm.
          # Pre-warm: under PRIME offload + finegrained PM the dGPU sits in D3cold
          # when idle, and NVENC's capability probe (early in OBS/ffmpeg/blender
          # startup) has a tight timeout that fails on first launch before the GPU
          # wakes / `nvidia_uvm` loads. nvidia-smi lifts it to D0 and forces
          # nvidia_uvm load — ~300ms, fixes "first OBS launch shows no NVENC".
          (pkgs.writeShellScriptBin "nvidia-offload" ''
            nvidia-smi >/dev/null 2>&1 || true
            export __NV_PRIME_RENDER_OFFLOAD=1
            export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
            export __GLX_VENDOR_LIBRARY_NAME=nvidia
            export __VK_LAYER_NV_optimus=NVIDIA_only
            exec "$@"
          '')
        ];

        # Default session to AMD iGPU so the dGPU can power down via RTD3;
        # use nvidia-offload for explicit GPU workloads.
        environment.sessionVariables = lib.mkIf cfg.prime.enable {
          __GLX_VENDOR_LIBRARY_NAME = "mesa";
          # Don't set VK_DRIVER_FILES - Vulkan auto-discovers; nvidia-offload
          # uses __VK_LAYER_NV_optimus to select NVIDIA for Vulkan.
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
        # Blacklist nouveau to prevent it from claiming the dGPU — nouveau lacks
        # proper suspend support for newer GPUs and can cause s2idle crashes
        boot.blacklistedKernelModules = [ "nouveau" ];

        # Force-disable nvidia suspend/resume/hibernate so empty-ExecStart
        # services don't block suspend in the no-nvidia specialisation.
        hardware.nvidia.powerManagement.kernelSuspendNotifier = lib.mkForce false;
        systemd.services.nvidia-suspend.enable = lib.mkForce false;
        systemd.services.nvidia-resume.enable = lib.mkForce false;
        systemd.services.nvidia-hibernate.enable = lib.mkForce false;
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
