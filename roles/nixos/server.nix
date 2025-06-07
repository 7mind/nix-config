{ config, lib, ... }:

{
  options = {
    smind.isServer = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };

    smind.roles.server.generic = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.roles.server.generic {
    smind = {
      isServer = lib.mkDefault true;
      isDesktop = false;
      roles.desktop.generic-gnome = false;

      environment.linux.sane-defaults.enable = lib.mkDefault true;
      zsh.enable = lib.mkDefault true;
      nushell.enable = lib.mkDefault false;
    };
  };
}
