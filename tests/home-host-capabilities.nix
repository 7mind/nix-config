{ lib, pkgs }:
let
  profiles = [
    { name = "pavel-am5"; path = ../home/pavel-am5.nix; model = "qwen3.8-27b-q8"; }
    { name = "pavel-fw"; path = ../home/pavel-fw.nix; model = "qwen3.8-27b-q4"; }
  ] ++ lib.optional (builtins.pathExists ../private/modules/hm/dev-llm-private.nix) {
    name = "vm";
    path = ../private/modules/hm/dev-llm-private.nix;
    model = "qwen3.8-27b-q4";
  };
  evaluate = profile: capability:
    (lib.evalModules {
      specialArgs = {
        inherit pkgs;
        smind-hm.imports = [ ];
        cfg-meta.paths.users = "unused";
        extended_pkg = null;
        xdg_associate = null;
        import_if_exists = null;
        import_if_exists_or = null;
        ageUserSecret = import ../lib/age-user-secret.nix;
      };
      modules = [
        ../modules/hm/globals.nix
        ({ config, ... }@args: builtins.removeAttrs (import profile.path args) [ "imports" ])
        {
          options = {
            assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = [ ]; };
            home.file = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
            programs.pi.configDir = lib.mkOption { type = lib.types.str; };
            smind.hm.dev.llm.enable = lib.mkOption { type = lib.types.bool; };
          };
          config = {
            _module.check = false;
            programs.pi.configDir = ".pi/agent";
            smind.hm.globals.llama-swap = capability;
            smind.hm.dev.llm.enable = true;
          };
        }
      ] ++ lib.optional (profile.name == "vm") {
        smind.hm.dev.llm.pi.llamaSwap.enable = true;
      };
    }).config;
  failures = config: builtins.filter (a: !a.assertion) config.assertions;
  check = profile:
    let
      disabled = evaluate profile { enable = false; port = null; models = { }; };
      enabled = evaluate profile {
        enable = true;
        port = 8080;
        models = { ${profile.model} = { }; "${profile.model}-abliterated" = { }; };
      };
      missingModels = evaluate profile { enable = true; port = 8080; models = { }; };
      missingPort = evaluate profile {
        enable = true;
        port = null;
        models = { ${profile.model} = { }; "${profile.model}-abliterated" = { }; };
      };
    in
    assert lib.assertMsg (failures disabled == [ ]) "${profile.name}: disabled service must not fail assertions";
    assert lib.assertMsg (!(disabled.home.file ? ".pi/agent/models.json")) "${profile.name}: disabled service must not generate Pi models";
    assert lib.assertMsg (failures enabled == [ ]) "${profile.name}: valid service must pass assertions";
    assert lib.assertMsg (enabled.home.file ? ".pi/agent/models.json") "${profile.name}: enabled service must generate Pi models";
    assert lib.assertMsg (builtins.isString (toString enabled.home.file.".pi/agent/models.json".source)) "${profile.name}: provider source must evaluate";
    assert lib.assertMsg (builtins.length (failures missingModels) == 1) "${profile.name}: enabled service must validate models";
    assert lib.assertMsg (builtins.length (failures missingPort) == 1) "${profile.name}: enabled service must validate its port";
    { name = profile.name; value = true; };
in
builtins.listToAttrs (map check profiles)
