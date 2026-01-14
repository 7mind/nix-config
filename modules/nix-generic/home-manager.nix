{ config, lib, specialArgsSelfRef, ... }:

{

  options = {
    smind.home-manager.enable = lib.mkEnableOption "home-manager integration";
  };

  config = lib.mkIf config.smind.home-manager.enable {
    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.extraSpecialArgs = specialArgsSelfRef;
    home-manager.sharedModules = specialArgsSelfRef.cfg-hm-modules;
    home-manager.backupFileExtension = "hmbak";
  };
}
