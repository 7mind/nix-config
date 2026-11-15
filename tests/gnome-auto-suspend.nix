{ pkgs }:
let
  lib = pkgs.lib;
  evaluated = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit pkgs;
    system = pkgs.stdenv.hostPlatform.system;
    specialArgs.cfg-meta = { };
    modules = [
      ../modules/nixos/gnome.nix
      ../modules/nixos/mouse.nix
      ({ lib, ... }: {
        options.smind = {
          isLaptop = lib.mkOption { type = lib.types.bool; default = false; };
          desktop.xkb = lib.mkOption {
            type = lib.types.attrs;
            default = { layouts = [ "us" ]; options = [ "caps:escape" ]; };
          };
          desktop.wayland.session-variables.enable = lib.mkEnableOption "Wayland session variables";
          power-management.powerButton = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          security.keyring = lib.mkOption { type = lib.types.attrs; };
        };
        config = {
          system.stateVersion = "26.05";
          # Laptop discriminates the onAC default: it used to be "suspend".
          smind.isLaptop = true;
          smind.desktop.gnome.enable = true;
        };
      })
    ];
  };
  profile = evaluated.config.programs.dconf.profiles.user;
  powerPath = "org/gnome/settings-daemon/plugins/power";
  locked = database: key:
    builtins.elem "/${powerPath}/${key}" database.locks
    || (database.lockAll && (database.settings.${powerPath} or { }) ? ${key});
  defaults = lib.foldl' (result: database: result // (database.settings.${powerPath} or { })) { } profile.databases;
  profileDirectory = evaluated.config.environment.etc.dconf.source;
in
# BG @specified: "Automatic Suspend / When Plugged In" (action + delay) must stay
# user-tunable in GNOME Settings and default to never on AC power.
assert lib.assertMsg (builtins.all (database: !(locked database "sleep-inactive-ac-type") && !(locked database "sleep-inactive-ac-timeout")) profile.databases)
  "AC auto-suspend action and delay must remain user-writable";
assert lib.assertMsg (defaults.sleep-inactive-ac-type == "nothing"
  && toString defaults.sleep-inactive-ac-timeout == toString (lib.gvariant.mkInt32 7200))
  "AC auto-suspend must default to never (sleep-inactive-ac-type = 'nothing')";
assert lib.assertMsg (builtins.any (database: locked database "sleep-inactive-battery-type") profile.databases
  && builtins.any (database: locked database "sleep-inactive-battery-timeout") profile.databases)
  "On-battery auto-suspend must retain its existing lock policy";
pkgs.runCommand "gnome-auto-suspend" {
  nativeBuildInputs = [ pkgs.dconf pkgs.dbus ];
} ''
  export HOME="$TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_RUNTIME_DIR="$TMPDIR/runtime"
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
  export DCONF_PROFILE=${profileDirectory}/profile/user
  export XDG_DATA_DIRS=${pkgs.dconf}/share
  dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- sh -eux -c '
    test "$(dconf read /${powerPath}/sleep-inactive-ac-type)" = "'"'"'nothing'"'"'"
    dconf write /${powerPath}/sleep-inactive-ac-type "'"'"'suspend'"'"'"
    dconf write /${powerPath}/sleep-inactive-ac-timeout 1800
    test "$(dconf read /${powerPath}/sleep-inactive-ac-type)" = "'"'"'suspend'"'"'"
    test "$(dconf read /${powerPath}/sleep-inactive-ac-timeout)" = "1800"
    dconf reset /${powerPath}/sleep-inactive-ac-type
    dconf reset /${powerPath}/sleep-inactive-ac-timeout
    test "$(dconf read /${powerPath}/sleep-inactive-ac-type)" = "'"'"'nothing'"'"'"
    test "$(dconf read /${powerPath}/sleep-inactive-ac-timeout)" = "7200"
    if dconf write /${powerPath}/sleep-inactive-battery-type "'"'"'nothing'"'"'"; then
      echo "On-battery auto-suspend policy unexpectedly writable" >&2
      exit 1
    fi
  '
  touch "$out"
''
