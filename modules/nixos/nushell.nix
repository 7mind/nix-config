{ pkgs, lib, config, ... }: {
  options = {
    smind.nushell.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Configure nushell as default shell for all users";
    };
  };

  config = lib.mkIf config.smind.nushell.enable {
    environment.shells = with pkgs; [ nushell ];

    users = {
      defaultUserShell = pkgs.nushell;
    };
  };

}
