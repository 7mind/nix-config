{ config, lib, ... }:

{
  options = {
    smind.isServer = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Host is a server system";
    };

    smind.roles.server.generic = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable generic server role";
    };
  };

  config = lib.mkIf config.smind.roles.server.generic {
    smind = {
      isServer = lib.mkDefault true;
      isDesktop = false;
      roles.desktop.generic-gnome = false;

      environment.linux.sane-defaults.enable = lib.mkDefault true;
      shell.zsh.enable = lib.mkDefault true;
      shell.nushell.enable = lib.mkDefault false;
    };
  };
}
