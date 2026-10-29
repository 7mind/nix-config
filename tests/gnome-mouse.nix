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
          smind.desktop.gnome = {
            enable = true;
            mouse.acceleration = 0.25;
            mouse.accelProfile = "flat";
          };
        };
      })
    ];
  };
  profile = evaluated.config.programs.dconf.profiles.user;
  mousePath = "org/gnome/desktop/peripherals/mouse";
  locked = database: key:
    builtins.elem "/${mousePath}/${key}" database.locks
    || (database.lockAll && (database.settings.${mousePath} or { }) ? ${key});
  defaults = lib.foldl' (result: database: result // (database.settings.${mousePath} or { })) { } profile.databases;
  profileDirectory = evaluated.config.environment.etc.dconf.source;
in
# BG @regression: system defaults must not prevent per-user mouse acceleration changes.
assert lib.assertMsg (builtins.all (database: !(locked database "speed") && !(locked database "accel-profile")) profile.databases)
  "GNOME mouse speed and acceleration profile must remain user-writable";
assert lib.assertMsg (toString defaults.speed == toString (lib.gvariant.mkDouble 0.25) && defaults.accel-profile == "flat")
  "GNOME must retain configured mouse defaults";
assert lib.assertMsg (builtins.any (database: database.lockAll && database.settings ? "org/gnome/desktop/interface") profile.databases)
  "Unrelated GNOME settings must retain their existing lock policy";
pkgs.runCommand "gnome-mouse" {
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
    dconf write /${mousePath}/speed 0.5
    test "$(dconf read /${mousePath}/speed)" = 0.5
    dconf write /${mousePath}/accel-profile "\"adaptive\""
    test "$(dconf read /${mousePath}/accel-profile)" = "'"'"'adaptive'"'"'"
    if dconf write /org/gnome/desktop/interface/clock-show-weekday false; then
      echo "Unrelated GNOME policy unexpectedly writable" >&2
      exit 1
    fi
    dconf reset /${mousePath}/speed
    test "$(dconf read /${mousePath}/speed)" = 0.25
  '
  touch "$out"
''
