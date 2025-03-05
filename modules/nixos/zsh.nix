{ pkgs, lib, config, ... }: {
  options = {
    smind.zsh.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Configure zsh as default shell for all users";
    };
  };

  config = lib.mkIf config.smind.zsh.enable {
    programs.zsh.enable = true;

    environment.shells = with pkgs; [ zsh ];

    users = {
      defaultUserShell = pkgs.zsh;
    };
  };

}
