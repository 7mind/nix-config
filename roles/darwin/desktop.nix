{ config, lib, ... }:

{
  options = {
    smind.isDesktop = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Host is a macOS desktop system";
    };
  };
}
