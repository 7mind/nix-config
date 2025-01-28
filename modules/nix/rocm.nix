{ pkgs, lib, config, ... }: {
  options = {
    smind.hw.rocm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hw.rocm.enable {
    nixpkgs.config.rocmSupport = true;

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
      extraPackages = [
        pkgs.rocmPackages.clr
      ];
    };

    boot.kernelParams = [ "amdgpu.ppfeaturemask=0xffffffff" ];

    systemd.tmpfiles.rules = [
      "L+    /opt/rocm/hip   -    -    -     -    ${pkgs.rocmPackages.clr}"
    ];

    environment.systemPackages = with pkgs; [
      clinfo
      rocmPackages.rocminfo
    ];
  };

}
