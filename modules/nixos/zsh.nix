{ pkgs, lib, config, ... }: {
  options = {
    smind.shell.zsh.enable = lib.mkEnableOption "zsh as default shell for all users";
  };

  config = lib.mkIf config.smind.shell.zsh.enable {
    programs.zsh.enable = true;

    environment.shells = with pkgs; [ zsh ];

    users = {
      defaultUserShell = pkgs.zsh;
    };
  };

}
