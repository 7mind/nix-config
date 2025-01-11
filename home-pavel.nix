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
    telegram-desktop
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

  home.file = builtins.listToAttrs
    (map
      (pkg:
        {
          name = ".config/autostart/" + pkg.name + ".desktop";
          value.text = ''
            [Desktop Entry]
            Type=Application
            Version=1.0
            Name=${pkg.name}
            Exec=${pkg.exec}
            StartupNotify=false
            Terminal=false
          '';
        })

      # ${pkg.bin} ${lib.concatStringsSep " " (map (f: "\"${f}\"") pkg.flags)}
      (with pkgs; [
        {
          name = "element";
          exec = "${element-desktop}/bin/element-desktop --hidden";
        }
        {
          name = "slack";
          exec = "${slack}/bin/slack -u";
        }
        {
          name = "telegram-desktop";
          exec = "${pkgs.telegram-desktop}/bin/telegram-desktop -startintray";
        }
      ])
    );

  #services.gnome-keyring = {
  #  enable = true;
  #  components = [ "pkcs11" "secrets" "ssh" ];
  #};
}

