{ pkgs }:
let
  lib = pkgs.lib;
  fixturePkgs = pkgs // { netns-run = pkgs.hello; };
  helpers = import ../lib/lib.nix { inherit lib; pkgs = fixturePkgs; cfg-meta = { }; cfg-const = { }; };
  evaluateWith = testPkgs: settings: (import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    specialArgs.wrapAppWithNetnsSlice = helpers._module.args.wrapAppWithNetnsSlice;
    specialArgs.inputs = { };
    modules = [
      ../modules/nixos/steam.nix
      ../modules/nixos/steam-wrappers.nix
      ../modules/nixos/wanbond.nix
      ../modules/nixos/mt7927-wifi.nix
      ../modules/nixos/nas-autofs.nix
      ../modules/nixos/geoip.nix
      { nixpkgs.pkgs = testPkgs; system.stateVersion = "26.05"; }
      settings
    ];
  }).config;
  evaluate = evaluateWith pkgs;
  # Only caller-supplied firmware requires an explicit unfree evaluation allowance.
  firmwarePkgs = import pkgs.path {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfreePredicate = package: lib.hasPrefix "mt7927-firmware" (lib.getName package);
  };
  disabled = evaluate { };
  enabled = evaluate {
    smind.gaming.steam = {
      enable = true;
      # NixOS overrides Steam's environment and also installs its run output.
      package = lib.makeOverridable (_: pkgs.hello // { run = pkgs.hello; }) { };
      heroic.package = pkgs.hello;
      wrappers = { enable = true; sliceName = "games"; steam.netns = "game-net"; };
    };
    services.wanbond = {
      enable = true;
      role = "edge";
      package = pkgs.hello;
      template = "token = \"\${TOKEN}\"";
      secretFiles.TOKEN = "/run/fixture/token";
    };
    smind.nas-autofs = {
      enable = true;
      server = "storage.test";
      shares = [ "documents" "media" ];
      credentialsFile = "/run/fixture/cifs";
      uid = 1234;
      gid = 2345;
    };
    smind.services.geoip = {
      enable = true;
      key.enable = true;
      accountID = 42;
      licenseKeyFile = "/run/fixture/geoip";
    };
  };
  wifi = evaluateWith firmwarePkgs {
    boot.kernelPackages = pkgs.linuxPackages_7_2;
    smind.hw.mt7927 = {
      enable = true;
      driverZip = pkgs.writeText "fixture-driver.zip" "evaluation-only fixture";
    };
  };
  unsupportedWifi = evaluate {
    boot.kernelPackages = pkgs.linuxPackages_7_3;
    smind.hw.mt7927.enable = true;
  };
  missingZip = evaluateWith firmwarePkgs {
    boot.kernelPackages = pkgs.linuxPackages_7_2;
    smind.hw.mt7927.enable = true;
  };
  failedWifiAssertions = config: lib.filter (assertion:
    !assertion.assertion && lib.hasPrefix "smind.hw.mt7927:" assertion.message
  ) config.assertions;
  custom = evaluate {
    smind.nas-autofs = {
      enable = true;
      server = "storage.test";
      shares = [ "archive" ];
      credentialsFile = "/run/fixture/cifs";
      uid = 1;
      gid = 2;
      mountPoint = "/srv/shares";
      mountOptions = [ "ro" ];
      mountTimeout = "5s";
      idleTimeout = "30s";
    };
  };
  cifsMounts = config: lib.filter (mount: mount.type == "cifs") config.systemd.mounts;
  mount = builtins.head (cifsMounts enabled);
  automount = builtins.head enabled.systemd.automounts;
  customMount = builtins.head (cifsMounts custom);
  geo = enabled.services.geoipupdate.settings;
in
# BG @specified: evaluate generic caller inputs against real NixOS consumers.
assert disabled.boot.extraModulePackages == [ ];
assert !pkgs.stdenv.hostPlatform.isx86_64 || (
  builtins.length wifi.boot.extraModulePackages == 1
  && (builtins.head wifi.boot.extraModulePackages).pname == "mt7927-mt76"
  && lib.any (package: lib.hasInfix "mt7927-firmware" (toString package)) wifi.hardware.firmware.paths
  && failedWifiAssertions wifi == [ ]
  && builtins.length (failedWifiAssertions unsupportedWifi) == 1
  && !(builtins.tryEval missingZip.hardware.firmware.drvPath).success
);
assert cifsMounts disabled == [ ] && disabled.systemd.automounts == [ ];
assert !(disabled.systemd.services ? wanbond-edge) && !disabled.services.geoipupdate.enable;
assert enabled.systemd.user.slices.games.sliceConfig.CPUQuota == "100%";
assert lib.hasInfix "-n game-net -s games.slice" enabled.smind.gaming.steam.wrappedPackage.wrapperScript;
assert lib.hasInfix "-s games.slice" enabled.smind.gaming.steam.heroic.wrappedPackage.wrapperScript;
assert enabled.systemd.services.wanbond-edge.requires == [ "wanbond-render-edge.service" ];
assert enabled.systemd.services.wanbond-edge.serviceConfig.UMask == "0077";
assert enabled.systemd.services.wanbond-render-edge.unitConfig.ConditionPathExists == [ "/run/fixture/token" ];
assert lib.hasInfix "chmod 0600 /run/wanbond/edge.toml.tmp" enabled.systemd.services.wanbond-render-edge.script;
assert builtins.length (cifsMounts enabled) == 2;
assert mount.what == "//storage.test/documents" && mount.where == "/mnt/nas/documents";
assert lib.hasInfix "credentials=/run/fixture/cifs,uid=1234,gid=2345" mount.options;
assert mount.mountConfig.TimeoutSec == "10s" && mount.unitConfig.Conflicts == [ "sleep.target" ];
assert automount.automountConfig.TimeoutIdleSec == "60";
assert !(automount.unitConfig ? Conflicts);
assert customMount.options == "credentials=/run/fixture/cifs,uid=1,gid=2,ro";
assert customMount.where == "/srv/shares/archive" && customMount.mountConfig.TimeoutSec == "5s";
assert (builtins.head custom.systemd.automounts).automountConfig.TimeoutIdleSec == "30s";
assert geo.AccountID == 42 && geo.LicenseKey._secret == "/run/fixture/geoip";
assert geo.DatabaseDirectory == "/var/lib/GeoIP/db";
assert geo.EditionIDs == [ "GeoLite2-ASN" "GeoLite2-City" "GeoLite2-Country" ];
assert lib.any (package: package.name == "tripc") enabled.environment.systemPackages;
pkgs.runCommand "promoted-core-evaluation" { } "touch $out"
