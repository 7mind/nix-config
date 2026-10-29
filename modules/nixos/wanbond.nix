{ config, lib, pkgs, inputs, ... }:

# Render secret-bearing TOML into a mode-0600 runtime file before startup.
# Interface addressing and routing remain the caller's responsibility.
let
  cfg = config.services.wanbond;
  runFile = "/run/wanbond/${cfg.role}.toml";
in {
  options.services.wanbond = {
    enable = lib.mkEnableOption "wanbond bonded-WAN tunnel daemon";

    role = lib.mkOption {
      type = lib.types.enum [ "edge" "concentrator" ];
      description = "wanbond role; selects the unit name wanbond-<role>.service.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.wanbond.packages.${pkgs.stdenv.hostPlatform.system}.default;
      description = "wanbond package from the wanbond flake input.";
    };

    template = lib.mkOption {
      type = lib.types.lines;
      description = ''
        The wanbond TOML with `''${VAR}` placeholders for each secret named in
        `secretFiles`. Rendered to a 0600 /run file via envsubst before service startup.
        Non-secret values (peer public keys, endpoints, addressing) are inlined
        directly; only the entries in `secretFiles` are substituted.
      '';
    };

    secretFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        Map of ENV-VAR name -> runtime secret file path. Each file's content is
        substituted for `''${ENV-VAR}` in `template`. Only these names are
        substituted (envsubst is given an explicit allow-list), so TOML content
        is never mangled.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    systemd.tmpfiles.rules = [ "d /run/wanbond 0700 root root -" ];

    # Assemble the 0600 config out of the store, injecting runtime secrets.
    systemd.services."wanbond-render-${cfg.role}" = {
      description = "Render wanbond ${cfg.role} config (inject secrets, keep out of the store)";
      requiredBy = [ "wanbond-${cfg.role}.service" ];
      before = [ "wanbond-${cfg.role}.service" ];
      # Skip cleanly (no failure) until every secret is available.
      unitConfig.ConditionPathExists = lib.mapAttrsToList (_: path: "${path}") cfg.secretFiles;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      script =
        let
          tmpl = pkgs.writeText "wanbond-${cfg.role}.toml.tmpl" cfg.template;
          exports = lib.concatStringsSep "\n"
            (lib.mapAttrsToList (v: path: ''export ${v}="$(cat ${path})"'') cfg.secretFiles);
          # Explicit allow-list so envsubst only touches our placeholders.
          allow = lib.concatStringsSep "" (lib.mapAttrsToList (v: _: "\$${v} ") cfg.secretFiles);
        in
        ''
          set -euo pipefail
          install -d -m 0700 /run/wanbond
          ${exports}
          ${pkgs.envsubst}/bin/envsubst '${allow}' < ${tmpl} > ${runFile}.tmp
          chmod 0600 ${runFile}.tmp
          mv -f ${runFile}.tmp ${runFile}
        '';
    };

    systemd.services."wanbond-${cfg.role}" = {
      description = "wanbond bonded WAN tunnel (${cfg.role} role)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "wanbond-render-${cfg.role}.service" ];
      wants = [ "network-online.target" ];
      requires = [ "wanbond-render-${cfg.role}.service" ];
      unitConfig.ConditionPathExists = runFile;
      # The daemon shells out to `nft` for its TCP MSS clamp and `tc` for TUN AQM.
      path = [ pkgs.nftables pkgs.iproute2 ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${cfg.package}/bin/wanbond --config ${runFile}";
        # SIGHUP re-reads config + applies the path/peer diff without tearing
        # down the live tunnel.
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = "2s";
        # Hardening — mirrors packaging/systemd/wanbond-<role>.service upstream.
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        DeviceAllow = [ "/dev/net/tun rw" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_NETLINK" "AF_UNIX" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        UMask = "0077";
      };
    };
  };
}
