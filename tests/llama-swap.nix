{ pkgs, inputs }:
let
  lib = pkgs.lib;
  evaluate = modules: (import (inputs.nixpkgs + "/nixos/lib/eval-config.nix") {
    inherit pkgs;
    system = pkgs.stdenv.hostPlatform.system;
    modules = [
      ../modules/nixos/llama-swap.nix
      { system.stateVersion = "26.05"; }
    ] ++ modules;
  }).config;
  server = pkgs.hello;
  commonArgs = [ "--threads" "2" ];
  modelArgs = {
    first = [ "--fixture" "value with spaces" "quote's" "$(not-a-command)" ];
    second = [ "--fixture" "another-value" ];
  };
  native = {
    services.llama-swap = {
      package = pkgs.llama-swap;
      listenAddress = "127.0.0.1";
      port = 12345;
      openFirewall = true;
      settings = {
        healthCheckTimeout = 300;
        globalTTL = 60;
        models.first.aliases = [ "alias" ];
      };
    };
  };
  integration = {
    environment = { GPU_BACKEND = "fixture"; };
    supplementaryGroups = [ "render" "video" ];
    networkOnline = true;
    memoryDenyWriteExecute = false;
    privateUsers = false;
  };
  generated = evaluate [ native {
    smind.services.llama-swap = integration // {
      enable = true;
      package = server;
      inherit commonArgs;
      models = modelArgs;
    };
  } ];
  # BG @specified: compare against explicit native configuration, independent of
  # the wrapper's implementation, to preserve argument order and service policy.
  explicit = evaluate [ native {
    environment.systemPackages = [ server ];
    services.llama-swap = {
      enable = true;
      settings.models = lib.mapAttrs (_: args: {
        cmd = lib.escapeShellArgs ([
          "${server}/bin/llama-server" "--host" "127.0.0.1" "--port" "\${PORT}"
        ] ++ args ++ commonArgs);
        proxy = "http://127.0.0.1:\${PORT}";
      }) modelArgs;
    };
    systemd.services.llama-swap = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = integration.environment;
      serviceConfig = {
        SupplementaryGroups = integration.supplementaryGroups;
        MemoryDenyWriteExecute = lib.mkForce false;
        PrivateUsers = lib.mkForce false;
      };
    };
  } ];
  project = config: {
    inherit (config.services.llama-swap) settings listenAddress port openFirewall;
    package = config.services.llama-swap.package.drvPath;
    packages = map (p: p.drvPath) config.environment.systemPackages;
    firewall = config.networking.firewall.allowedTCPPorts;
    inherit (config.systemd.services.llama-swap) after wants environment serviceConfig;
  };
  defaults = evaluate [ { smind.services.llama-swap.enable = true; } ];
  disabled = evaluate [ { } ];
  nativeOnly = evaluate [ native { services.llama-swap.enable = true; } ];
  defaultUnit = defaults.systemd.services.llama-swap;
  invalid = evaluate [ {
    smind.services.llama-swap = { enable = true; models.invalid = "not an argument list"; };
  } ];
in
assert lib.assertMsg (project generated == project explicit) "Generated commands and service behavior must match explicit native configuration";
assert lib.assertMsg (generated.services.llama-swap.settings.models.first.aliases == [ "alias" ]) "Native per-model settings must merge with generated commands";
assert lib.assertMsg (lib.hasInfix "'\${PORT}'" generated.services.llama-swap.settings.models.first.cmd) "The dynamic port placeholder must survive shell escaping";
assert lib.assertMsg (defaults.smind.services.llama-swap.package.drvPath == pkgs.llama-cpp.drvPath) "The default backend must be the supplied package set's llama-cpp";
assert lib.assertMsg (defaultUnit.serviceConfig.MemoryDenyWriteExecute && defaultUnit.serviceConfig.PrivateUsers && defaultUnit.serviceConfig.SupplementaryGroups == [ ]) "Default integration must retain upstream hardening and grant no groups";
assert lib.assertMsg (!(lib.elem "network-online.target" defaultUnit.after) && defaultUnit.wants == [ ]) "Network-online must remain opt-in";
assert lib.assertMsg (!disabled.services.llama-swap.enable && !(disabled.systemd.services ? llama-swap)) "Disabled integration must not create a service";
assert lib.assertMsg (nativeOnly.systemd.services.llama-swap.serviceConfig.PrivateUsers && !(lib.elem server nativeOnly.environment.systemPackages)) "Native service configuration must remain usable independently";
assert lib.assertMsg (!(builtins.tryEval (builtins.deepSeq invalid.services.llama-swap.settings.models true)).success) "Model arguments must reject strings instead of accepting shell commands";
pkgs.runCommand "llama-swap-evaluation" { } "touch $out"
