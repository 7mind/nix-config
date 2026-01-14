{ config, lib, ... }:

{
  options = {
    smind.zram-swap.enable = lib.mkEnableOption "zram-based swap with zstd compression";
  };

  config = lib.mkIf config.smind.zram-swap.enable {
    zramSwap = {
      enable = true;
      algorithm = "zstd";
      memoryPercent = 50;
      priority = 10;
    };
  };
}
