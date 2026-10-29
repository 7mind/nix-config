{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.llama-swap;
  sandboxOverride = name: value: lib.optionalAttrs (value != null) {
    ${name} = lib.mkForce value;
  };
in
{
  options.smind.services.llama-swap = {
    enable = lib.mkEnableOption "llama-server command generation and GPU integration for services.llama-swap";

    package = lib.mkPackageOption pkgs "llama-cpp" { };

    commonArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Arguments appended after each model's arguments. Host and dynamically allocated port are supplied automatically.";
    };

    models = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      description = ''
        Model names mapped to llama-server argument lists. Each command is
        shell-escaped and uses the loopback proxy with llama-swap's PORT
        substitution. Additional model settings belong in services.llama-swap.settings.models.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Service environment, including explicit GPU backend selection when needed.";
    };

    supplementaryGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Supplementary groups needed by the selected GPU backend.";
    };

    networkOnline = lib.mkEnableOption "ordering after and pulling in network-online.target";

    memoryDenyWriteExecute = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Override the upstream MemoryDenyWriteExecute sandbox setting; null preserves it. JIT backends may require false.";
    };

    privateUsers = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Override the upstream PrivateUsers sandbox setting; null preserves it. GPU device groups may require false.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    services.llama-swap = {
      enable = true;
      settings.models = lib.mapAttrs (_: args: {
        cmd = lib.escapeShellArgs (
          [
            (lib.getExe' cfg.package "llama-server")
            "--host"
            "127.0.0.1"
            "--port"
            "\${PORT}"
          ] ++ args ++ cfg.commonArgs
        );
        proxy = "http://127.0.0.1:\${PORT}";
      }) cfg.models;
    };

    systemd.services.llama-swap = {
      after = lib.optionals cfg.networkOnline [ "network-online.target" ];
      wants = lib.optionals cfg.networkOnline [ "network-online.target" ];
      environment = cfg.environment;
      serviceConfig = {
        SupplementaryGroups = cfg.supplementaryGroups;
      } // sandboxOverride "MemoryDenyWriteExecute" cfg.memoryDenyWriteExecute
        // sandboxOverride "PrivateUsers" cfg.privateUsers;
    };
  };
}
