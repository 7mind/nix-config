{ config, lib, ... }:

{
  options = {
    smind.isDesktop = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Host is a macOS desktop system";
    };
  };

  config = {
    # macOS hosts are always desktops, so load owner secrets by default
    smind.age.load-owner-secrets = lib.mkDefault true;
  };
}
