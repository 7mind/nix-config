{ flake }:
let
  lib = flake.inputs.nixpkgs.lib;
  build = flake.globals.make-home-from-modules { inputs = flake.inputs; self = flake; };
  evaluate = settings: (build {
    username = "svcfixture";
    host = {
      hostname = "service-fixture";
      system = "x86_64-linux";
      homeDirectories.svcfixture = "/srv/homes/svcfixture";
      globals.isDesktop = false;
    };
    modules = [
      ({ smind-hm, ... }: { imports = smind-hm.imports; smind.hm.roles.server = true; })
      settings
    ];
  }).value.config;
  disabled = evaluate { };
  provider = evaluate {
    ponygirls.servicePostgres = {
      enable = true;
      stateDirectory = "/srv/homes/svcfixture/.local/state/ponygirls-postgres-18";
      adminRole = "svcfixture";
      port = 15434;
      databases = lib.genAttrs [ "chronicle" "haystack" "manure" ] (name: {
        inherit name;
        user = name;
        passwordFile = "/run/service-fixture/${name}-database-password";
        createPassword = false;
      });
    };
  };
  appsDisabled = config:
    !config.smind.hm.services.agentic.enable
    && !config.smind.hm.services.chronicle.enable;
  providerUnits = lib.filter (name: lib.hasPrefix "ponygirls-" name)
    (builtins.attrNames provider.systemd.user.services);
in
assert appsDisabled disabled && !disabled.ponygirls.servicePostgres.enable;
assert !(disabled.systemd.user.services ? ponygirls-postgres);
assert appsDisabled provider;
assert lib.sort builtins.lessThan providerUnits == [
  "ponygirls-database-chronicle" "ponygirls-database-haystack"
  "ponygirls-database-manure" "ponygirls-postgres"
];
assert lib.all (name:
  provider.ponygirls.servicePostgres.connections.${name}.jdbcUrl
    == "jdbc:postgresql://127.0.0.1:15434/${name}"
  && provider.ponygirls.servicePostgres.connections.${name}.databasePasswordFile
    == "/run/service-fixture/${name}-database-password"
) [ "chronicle" "haystack" "manure" ];
assert builtins.filter (entry: !entry.assertion) provider.assertions == [ ];
{
  disabledByDefault = true;
  independentlyProvisionedDatabases = true;
  threeCredentialBindings = true;
}
