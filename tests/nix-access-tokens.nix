{ pkgs, home-manager }:
let
  lib = pkgs.lib;
  makeHome = managed: home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      ../modules/hm/nix-access-tokens.nix
      {
        home = {
          username = "token-test";
          homeDirectory = "/build/home";
          stateVersion = "26.05";
        };
        nix.package = if managed then pkgs.nix else null;
        nix.settings = lib.optionalAttrs managed {
          experimental-features = [ "nix-command" "flakes" ];
        };
        smind.hm.nix.githubAccessTokenFile = "/build/token";
      }
    ];
  };
  config = (makeHome true).config;
  unmanagedConfig = (makeHome false).config;
  activateTokenFor = config: pkgs.writeShellScript "activate-github-token" ''
    set -euo pipefail
    ${config.home.activation.nix-github-access-token.data}
  '';
  activateToken = activateTokenFor config;
  activateUnmanagedToken = activateTokenFor unmanagedConfig;
in
# Effectual-GoodCommunication @regression: runtime tokens must coexist with HM's read-only nix.conf.
pkgs.runCommand "nix-access-tokens" { nativeBuildInputs = [ pkgs.nix pkgs.jq ]; } ''
  export HOME=/build/home
  export XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$XDG_CONFIG_HOME/nix"
  ln -s ${config.xdg.configFile."nix/nix.conf".source} "$XDG_CONFIG_HOME/nix/nix.conf"
  printf 'fixture-token' > /build/token
  ${activateToken}
  test -L "$XDG_CONFIG_HOME/nix/nix.conf"
  nix --extra-experimental-features nix-command config show --json > settings.json
  jq -e '."access-tokens".value."github.com" == "fixture-token"' settings.json
  jq -e '."experimental-features".value | contains(["nix-command", "flakes"])' settings.json
  test "$(stat -c %a "$XDG_CONFIG_HOME/nix/github-access-token.conf")" = 600
  chmod 0644 "$XDG_CONFIG_HOME/nix/github-access-token.conf"
  printf 'rotated-fixture-token' > /build/token
  ${activateToken}
  test "$(stat -c %a "$XDG_CONFIG_HOME/nix/github-access-token.conf")" = 600
  nix --extra-experimental-features nix-command config show --json \
    | jq -e '."access-tokens".value."github.com" == "rotated-fixture-token"'
  rm "$XDG_CONFIG_HOME/nix/nix.conf"
  ${activateUnmanagedToken}
  test ! -L "$XDG_CONFIG_HOME/nix/nix.conf"
  test "$(stat -c %a "$XDG_CONFIG_HOME/nix/nix.conf")" = 600
  nix --extra-experimental-features nix-command config show --json \
    | jq -e '."access-tokens".value."github.com" == "rotated-fixture-token"'
  touch "$out"
''
