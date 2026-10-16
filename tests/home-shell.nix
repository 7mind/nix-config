{ pkgs, home-manager }:
let
  lib = pkgs.lib;
  home = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs = {
      cfg-const = (import ../config.nix).const;
      cfg-meta.isLinux = pkgs.stdenv.hostPlatform.isLinux;
      xdg_associate = null;
    };
    modules = [
      ../modules/hm/globals.nix
      ../modules/hm/env-settings-generic.nix
      ../modules/hm/zsh.nix
      {
        options.smind.hm = {
          roles.desktop = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          wezterm.enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
        };
        config = {
          home = {
            username = "shell-test";
            homeDirectory = "/build/home";
            stateVersion = "26.05";
          };
          smind.hm.zsh.enable = true;
        };
      }
    ];
  };
  config = home.config;
  rc = pkgs.writeText "home-shell.zshrc" config.programs.zsh.initContent;
in
# BG @regression: shared shell aliases must work without OS-installed packages.
pkgs.runCommand "home-shell"
  {
    nativeBuildInputs = [ pkgs.zsh ];
  }
  ''
    export HOME=/build/home
    export XDG_CACHE_HOME="$HOME/.cache"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_DATA_HOME="$HOME/.local/share"
    mkdir -p "$HOME" parent/child
    ${lib.optionalString config.programs.dircolors.enable ''
      cp ${config.home.file.".dir_colors".source} "$HOME/.dir_colors"
    ''}
    export PATH=${lib.makeBinPath (config.home.packages ++ [ pkgs.coreutils pkgs.gnugrep ])}
    cd parent/child
    zsh -dfi +o zle <<'ZSH'
    source ${rc}
    setopt errexit
    ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
      [[ "''${aliases[ls]-}" = 'lsd -lh --group-directories-first' ]] || { print -u2 -- 'Missing lsd ls alias'; exit 1; }
      [[ -n "''${LS_COLORS-}" ]] || { print -u2 -- 'Missing LS_COLORS initialization'; exit 1; }
      ls -la --color=always > "$HOME/colored-listing"
      grep -q $'\e\\[' "$HOME/colored-listing"
      ls -la > "$HOME/plain-listing"
      if grep -q $'\e\\[' "$HOME/plain-listing"; then
        print -u2 -- 'Redirected ls output must not contain colors'
        exit 1
      fi
    ''}
    la > "$HOME/listing"
    command -v lsd
    tree > "$HOME/tree"
    watch --help > /dev/null
    myip --version > /dev/null
    ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux "lsblk --help > /dev/null"}
    j ..
    [[ $PWD = */parent ]]
    cd child
    ..
    [[ $PWD = */parent ]]
    print -r -- shell-tests-passed > "$HOME/result"
    exit
    ZSH
    test "$(< "$HOME/result")" = shell-tests-passed
    touch "$out"
  ''
