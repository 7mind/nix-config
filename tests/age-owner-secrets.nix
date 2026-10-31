{ pkgs }:
let
  lib = pkgs.lib;
  evaluate = settings:
    (lib.evalModules {
      specialArgs = {
        cfg-meta = {
          isLinux = true;
          hostname = "test";
          paths.secrets = ./fixtures;
        };
        ageUserSecret = import ../lib/age-user-secret.nix;
      };
      modules = [
        ../modules/nix-generic/age.nix
        ({ lib, ... }: {
          options = {
            smind.host.owner = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            smind.age.enable = lib.mkEnableOption "age";
            age = {
              rekey = lib.mkOption { type = lib.types.attrs; default = { }; };
              secrets = lib.mkOption { type = lib.types.attrs; default = { }; };
            };
            lib = lib.mkOption { type = lib.types.attrs; default = { }; };
            assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = [ ]; };
          };
          config.age.rekey.hostPubkey = null;
        })
        settings
      ];
    }).config;
  passes = config: builtins.all (entry: entry.assertion) config.assertions;
  enabled = {
    smind.host.owner = "test";
    smind.age = {
      enable = true;
      load-owner-secrets = true;
      secretsFile = ./fixtures/age-owner-secrets.nix;
    };
  };
  defaults = evaluate { };
  nullOwner = evaluate { smind.age.enable = true; smind.age.load-owner-secrets = true; };
  loadingDisabled = evaluate {
    smind.host.owner = "test";
    smind.age.enable = true;
    smind.age.owner-secrets.include = [ "missing" ];
    smind.age.secretsFile = throw "Disabled owner loading must not read its secrets file";
  };
  ageDisabled = evaluate {
    smind.host.owner = "test";
    smind.age.load-owner-secrets = true;
    smind.age.secretsFile = throw "Disabled age must not read owner secrets";
  };
  matching = evaluate (lib.recursiveUpdate enabled {
    smind.age.owner-secrets.include = [ "mail-*" ];
  });
  unmatched = evaluate (lib.recursiveUpdate enabled {
    smind.age.owner-secrets.include = [ "missing*" ];
  });
  unmatchedExclude = evaluate (lib.recursiveUpdate enabled {
    smind.age.owner-secrets.exclude = [ "missing?" ];
  });
in
# BA @regression(issue=2): disabled owner loading must not force owner secret paths.
assert lib.assertMsg (passes defaults && defaults.age.secrets == { }) "Default configuration must not require an owner";
assert lib.assertMsg (passes nullOwner && (nullOwner.age.secrets or { }) == { }) "Null owner must skip owner secret loading";
assert lib.assertMsg (passes loadingDisabled && (loadingDisabled.age.secrets or { }) == { }) "Disabled owner loading must skip validation";
assert lib.assertMsg (passes ageDisabled && (ageDisabled.age.secrets or { }) == { }) "Disabled age must skip owner validation";
assert lib.assertMsg (passes matching && builtins.attrNames matching.age.secrets == [ "mail-password" ]) "Enabled owner loading must filter matching names";
assert lib.assertMsg (!passes unmatched) "Enabled owner loading must reject unmatched include patterns";
assert lib.assertMsg (!passes unmatchedExclude) "Enabled owner loading must reject unmatched exclude patterns";
pkgs.runCommand "age-owner-secrets" { } "touch $out"
