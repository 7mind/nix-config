{ config, lib, inputs, pkgs, ... }:

{
  imports = [ inputs.f4.homeManagerModules.f4 ];

  programs.f4 = lib.mkIf config.smind.hm.globals.environment.fileManagers.f4.enable {
    enable = true;
    package = if config.smind.hm.globals.isDesktop then
      inputs.f4.packages.${pkgs.stdenv.hostPlatform.system}.f4-gui
    else
      inputs.f4.packages.${pkgs.stdenv.hostPlatform.system}.f4-tty;
  };
}
