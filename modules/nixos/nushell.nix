{ pkgs, lib, config, ... }: {
  options = {
    smind.shell.nushell.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Configure nushell as default shell for all users";
    };
  };

  config = lib.mkIf config.smind.shell.nushell.enable {
    environment.shells = with pkgs; [ nushell ];

    users = {
      defaultUserShell = pkgs.nushell;
    };
  };

}
