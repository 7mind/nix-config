{ config, lib, specialArgsSelfRef, ... }:

{

  options = {
    smind.home-manager.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.home-manager.enable {
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.extraSpecialArgs = specialArgsSelfRef;
    home-manager.sharedModules = specialArgsSelfRef.cfg-hm-modules;
  };
}
