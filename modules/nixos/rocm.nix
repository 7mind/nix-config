{ pkgs, lib, config, ... }: {
  options = {
    smind.hw.amd.rocm.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.hw.amd.gpu.enable;
      description = "";
    };

    smind.hw.amd.gpu.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };

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


    hardware.amdgpu = {
      opencl.enable = true;
      initrd.enable = true;
      amdvlk.enable = true;
      amdvlk.supportExperimental.enable = true;
      amdvlk.support32Bit.enable = true;
    };

    hardware.graphics = {
      enable32Bit = true;
      enable = true;
      extraPackages = lib.mkIf config.smind.hw.amd.rocm.enable [
        pkgs.rocmPackages.clr
      ];
    };

    boot.kernelParams = [ "amdgpu.ppfeaturemask=0xffffffff" ];

    systemd.tmpfiles.rules = lib.mkIf config.smind.hw.amd.rocm.enable [
      "L+    /opt/rocm/hip   -    -    -     -    ${pkgs.rocmPackages.clr}"
    ];

    environment.systemPackages = with pkgs; [
      nvtopPackages.amd

      amdgpu_top

      radeon-profile
      radeontop
      radeontools

    ] ++ (if config.smind.hw.amd.rocm.enable then [
      rocmPackages.rocminfo
      rocmPackages.rocm-smi

      # zluda

      (python3.withPackages (python-pkgs: [
        python-pkgs.torchWithRocm
      ]))
    ] else [

    ]);
  };

}
