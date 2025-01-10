{ pkgs, lib, config, ... }: {

  home.stateVersion = "25.05";

  imports = [
    ./modules/hm/wezterm.nix
    ./modules/hm/htop.nix
    ./modules/hm/ssh.nix
    ./modules/hm/tmux.nix
    ./modules/hm/zsh.nix
    ./modules/hm/kitty.nix
    ./modules/hm/vscodium.nix
  ];

  home.packages = with pkgs; [
    firefox
    element-desktop
    bitwarden-desktop
    slack

    gitMinimal
    jetbrains.idea-ultimate
    visualvm
    vlc
  ];

  home.sessionVariables = {
    DOTNET_CLI_TELEMETRY_OPTOUT = "1";
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    config = {
      whitelist.prefix = [ "~/work/" ];
    };
  };

  home.activation.drop-mimeapps-list = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo >&2 "Removing ~/.config/mimeapps.list (it must be configured in nix)..."
    rm -f ${config.home.homeDirectory}/.config/mimeapps.list
  '';

  home.activation.hm-cleanup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo >&2 "Removing old profiles..."
    [[ "$USER" != "root" ]] && nix-env --profile ~/.local/state/nix/profiles/profile --delete-generations +5
    [[ "$USER" != "root" ]] && nix-env --profile ~/.local/state/nix/profiles/home-manager --delete-generations +5
  '';

}
