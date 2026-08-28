{ pkgs, lib, config, ... }: {
  options = {
    smind.hw.amd.rocm.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.hw.amd.gpu.enable;
      description = "Enable AMD ROCm compute stack";
    };

    smind.hw.amd.gpu.enable = lib.mkEnableOption "AMD GPU support with AMDGPU drivers";

  };

  config = lib.mkIf config.smind.hw.amd.gpu.enable {
    nixpkgs.config.rocmSupport = lib.mkIf config.smind.hw.amd.rocm.enable true;

    # Force compute power profile on desktops (not laptops - would hurt battery/thermals)
    services.udev.extraRules = lib.mkIf (config.smind.hw.amd.rocm.enable && !config.smind.isLaptop) ''
      ACTION=="add|change", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="manual"
      ACTION=="add|change", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/pp_power_profile_mode}="5"
    '';

    hardware.amdgpu = {
      opencl.enable = true;
      initrd.enable = true;
    };

    hardware.graphics = {
      enable32Bit = true;
      enable = true;
      extraPackages = lib.mkIf config.smind.hw.amd.rocm.enable [
        pkgs.rocmPackages.clr
      ];
    };

    # All PowerPlay features except GFXOFF (PP_GFXOFF_MASK, bit 15) on desktops:
    # GFXOFF causes hangs on idle, especially RDNA3 (RX 7000) — soft lockups in
    # amdgpu-reset-dev workqueue. Not fixed as of kernel 6.18 (Jan 2026).
    # Laptops keep defaults for battery life.
    # - https://gist.github.com/danielrosehill/6a531b079906f160911a87dea50e1507
    # - https://community.frame.work/t/linux-stability-patch-coming-to-kernel-6-18/75885
    # - https://wiki.archlinux.org/title/AMDGPU#Boot_parameter
    boot.kernelParams = lib.optionals (!config.smind.isLaptop) [
      "amdgpu.ppfeaturemask=0xffff7fff"
    ];

    systemd.tmpfiles.rules = lib.mkIf config.smind.hw.amd.rocm.enable [
      "L+    /opt/rocm/hip   -    -    -     -    ${pkgs.rocmPackages.clr}"
    ];

    environment.systemPackages = with pkgs; [
      amdgpu_top

      radeon-profile
      radeontop
      radeontools

    ] ++ (if config.smind.hw.amd.rocm.enable then [
      rocmPackages.rocminfo
      rocmPackages.rocm-smi
      # amd-smi replaces rocm-smi (ROCm 7.x ships both, rocm-smi deprecated).
      # Keep both on PATH while scripts still use the old name.
      rocmPackages.amdsmi

      (python3.withPackages (python-pkgs: [
        python-pkgs.torchWithRocm
      ]))
    ] else [

    ]);
  };

}
