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

    # https://github.com/NixOS/nixpkgs/issues/421822
    # nixpkgs.overlays = [
    #   (final: prev: {
    #     rocmPackages = prev.rocmPackages.overrideScope (rocmFinal: rocmPrev: {
    #       rocdbgapi = rocmPrev.rocdbgapi.override { buildDocs = false; };
    #     });
    #   })
    # ];

    # pytorch is broken:
    # https://github.com/NixOS/nixpkgs/blob/c8fadee69d99c39795e50754c1d0f4fb9b24cd65/pkgs/development/python-modules/torch/default.nix#L227
    # should be unblocked by: https://github.com/NixOS/nixpkgs/pull/367695

    nixpkgs.config.rocmSupport = lib.mkIf config.smind.hw.amd.rocm.enable true;
    # nixpkgs.config.packageOverrides = pkgs: {
    #   rocmPackages_6 = pkgs.rocmPackages_6.gfx1100;
    # };

    # Force compute power profile on desktops (not laptops - would hurt battery/thermals)
    services.udev.extraRules = lib.mkIf (config.smind.hw.amd.rocm.enable && !config.smind.isLaptop) ''
      ACTION=="add|change", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/power_dpm_force_performance_level}="manual"
      ACTION=="add|change", SUBSYSTEM=="drm", DRIVERS=="amdgpu", ATTR{device/pp_power_profile_mode}="5"
    '';

    hardware.amdgpu = {
      opencl.enable = true;
      initrd.enable = true;
      # radv enabled by default
      # amdvlk.enable = true;
      # amdvlk.supportExperimental.enable = true;
      # amdvlk.support32Bit.enable = true;
    };

    hardware.graphics = {
      enable32Bit = true;
      enable = true;
      extraPackages = lib.mkIf config.smind.hw.amd.rocm.enable [
        pkgs.rocmPackages.clr
      ];
    };

    # environment.variables = lib.mkIf config.smind.hw.amd.rocm.enable {
    #   ROCM_HOME = "${pkgs.rocmPackages.rocmPath}";
    # };

    # Enable all power management features EXCEPT GFXOFF on desktops.
    # GFXOFF causes system hangs when GPU enters idle/power-saving state, especially
    # on RDNA3 (RX 7000 series). The GPU fails to disable gfxoff during reset attempts,
    # leading to soft lockups in amdgpu-reset-dev workqueue.
    #
    # Known issue - not fixed as of kernel 6.18 (Jan 2026):
    # - https://gist.github.com/danielrosehill/6a531b079906f160911a87dea50e1507
    # - https://community.frame.work/t/linux-stability-patch-coming-to-kernel-6-18/75885
    # - https://wiki.archlinux.org/title/AMDGPU#Boot_parameter
    #
    # 0xffff7fff = all PowerPlay features except PP_GFXOFF_MASK (bit 15)
    # Laptops keep default behavior for battery life.
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

      # zluda # broken

      (python3.withPackages (python-pkgs: [
        python-pkgs.torchWithRocm
      ]))
    ] else [

    ]);
  };

}
