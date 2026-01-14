{ pkgs, lib, config, ... }: {
  options = {
    smind.shell.nushell.enable = lib.mkEnableOption "nushell as default shell for all users";
  };

  config = lib.mkIf config.smind.shell.nushell.enable {
    environment.shells = with pkgs; [ nushell ];

    users = {
      defaultUserShell = pkgs.nushell;
    };
  };

}
