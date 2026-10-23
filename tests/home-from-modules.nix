{ flake }:
let
  lib = flake.inputs.nixpkgs.lib;
  globals = flake.globals;
  build = globals.make-home-from-modules { inputs = flake.inputs; self = flake; };
  host = {
    hostname = "external-workstation";
    system = "x86_64-linux";
    homeDirectories.alex = "/srv/homes/alex";
    globals.isDesktop = false;
  };
  profile = { smind-hm, ... }: {
    imports = smind-hm.imports;
    smind.hm.roles.server = true;
    home.sessionVariables.EXTERNAL_PROFILE = "explicit";
  };
  home = build { modules = [ profile ]; username = "alex"; inherit host; };
  config = home.value.config;
  # Integrated hosts consume only .modules: no standalone inputs, self, or
  # architecture may be forced merely to select and apply those modules.
  lazy = globals.make-home-from-modules {
    inputs = throw "Standalone inputs were forced";
    self = throw "Standalone self was forced";
  } {
    modules = [ { home.sessionVariables.EXTERNAL_PROFILE = "lazy"; } ];
    username = "alex";
    host = builtins.removeAttrs host [ "system" "hostname" ];
  };
  legacy = globals.make-home { inputs = flake.inputs; self = flake; } {
    source = "root";
    username = "alex";
    inherit host;
  };
in
# WA @specified: inspect the required API arguments and returned metadata/modules.
assert lib.assertMsg (builtins.functionArgs build == { modules = false; username = false; host = false; }) "Explicit modules, username, and host must remain required";
assert lib.assertMsg (home.name == "alex@external-workstation-x86_64" && home.hostname == host.hostname && home.username == "alex") "Explicit-module instances must preserve naming and metadata";
assert lib.assertMsg (builtins.length home.modules == 2 && builtins.length legacy.modules == 2) "Both builders must append exactly one host-context module";
assert lib.assertMsg (builtins.head legacy.modules == builtins.head (globals.homeUserModules "root")) "Legacy source resolution must remain unchanged";
# BG @specified: evaluate real Home Manager configuration, context, and assertions.
assert lib.assertMsg (config.home.username == "alex" && config.home.homeDirectory == "/srv/homes/alex" && !config.smind.hm.globals.isDesktop) "Explicit modules must receive the supplied host context";
assert lib.assertMsg (config.home.sessionVariables.EXTERNAL_PROFILE == "explicit") "Explicit profile modules must be evaluated";
assert lib.assertMsg (builtins.filter (a: !a.assertion) config.assertions == [ ]) "Explicit-module configuration must pass assertions";
assert lib.assertMsg ((builtins.head lazy.modules).home.sessionVariables.EXTERNAL_PROFILE == "lazy" && (builtins.elemAt lazy.modules 1).home.homeDirectory == "/srv/homes/alex") "Integrated modules must not force standalone evaluation";
{
  explicitModules = true;
  legacySource = true;
  metadata = true;
  lazyIntegratedModules = true;
}
