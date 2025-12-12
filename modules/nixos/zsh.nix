{ pkgs, lib, config, ... }: {
  options = {
    smind.shell.zsh.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Configure zsh as default shell for all users";
    };
  };

  config = lib.mkIf config.smind.shell.zsh.enable {
    programs.zsh.enable = true;

    environment.shells = with pkgs; [ zsh ];

    users = {
      defaultUserShell = pkgs.zsh;
    };
  };

}
