{ pkgs, lib, config, ... }: {
  options = {
    smind.hw.rocm.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hw.rocm.enable {
    hardware.amdgpu = {
      opencl.enable = true;
      initrd.enable = true;
      amdvlk.enable = true;
      amdvlk.supportExperimental.enable = true;
      amdvlk.support32Bit.enable = true;
    };

    boot.kernelParams = "amdgpu.ppfeaturemask=0xffffffff";
  };

}
