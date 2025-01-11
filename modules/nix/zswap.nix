{ config, pkgs, lib, ... }:

{
  options = {
    smind.zram-swap = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Turn on zramSwap";
    };
  };

  # boot = {
  #   kernelPatches = [{
  #     name = "le9";
  #     patch = pkgs.fetchurl {
  #       url =
  #         "https://raw.githubusercontent.com/hakavlad/le9-patch/main/le9ec_patches/le9ec-5.15.patch";
  #       sha256 = "sha256-425MLHbDYIfwG5JRtLzNmsPWm5mQ2CTGi+z9s/imFxI=";
  #     };
  #   }
  #   # {
  #   #   name = "mglru";
  #   #   patch = null;
  #   #   extraConfig = ''
  #   #     LRU_GEN=y
  #   #     LRU_GEN_ENABLED=y
  #   #   '';
  #   # }
  #     ];

  #   kernel.sysctl = {
  #     "vm.anon_min_kbytes" = 1000000;
  #     "vm.clean_low_kbytes" = 2000000;
  #     "vm.clean_min_kbytes" = 1000000;
  #   };
  # };

  config = {
    zramSwap = lib.mkIf
      config.smind.zram-swap
      {
        enable = true;
        algorithm = "zstd";
        memoryPercent = 20;
        priority = 10;
      };
  };

}
