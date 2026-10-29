{ config, lib, pkgs, cfg-meta, ... }:

let
  host = config.smind.hm.globals;
  ageEnabled = host.age.enable;
  user = config.home.username;
  sourceFile = "${cfg-meta.paths.secrets}/${user}/age-secrets.nix";
  sources = if cfg-meta.isLinux && ageEnabled && host.age.secrets != { } then
    assert lib.assertMsg (builtins.pathExists sourceFile) "Missing user secret definitions: ${sourceFile}";
    import sourceFile { inherit cfg-meta; owner = user; group = "users"; }
    else { };
  projectedName = name: if builtins.hasAttr "${user}/${name}" host.age.secrets then "${user}/${name}" else name;
  selected = lib.filterAttrs (name: source:
    let projected = host.age.secrets.${projectedName name} or null;
    in projected != null && (projected.enable or true) && (source.enable or true)
      && projected.owner == user && (source.owner or user) == user
  ) sources;
  secrets = lib.mapAttrs' (name: source:
    let
      key = projectedName name;
      projected = host.age.secrets.${key};
      filename = source.name or name;
      relative = if lib.hasPrefix "${user}/" key then "${user}/${filename}" else filename;
      sourcePath = source.rekeyFile or null;
      pubkeyHash = builtins.hashString "sha256" host.age.hostPubkey;
      hash = builtins.substring 0 32 (builtins.hashString "sha256" (pubkeyHash + builtins.hashFile "sha256" sourcePath));
      directory = host.age.localStorageDir + lib.optionalString (host.owner != user) "-${user}";
      file = "${directory}/${hash}-${filename}.age";
    in
    assert lib.assertMsg (filename != "." && filename != ".." && builtins.match "[a-zA-Z0-9_.-]+" filename != null) "Unsupported user secret name: ${filename}";
    assert lib.assertMsg (projected.path == "/run/agenix/${relative}" && (relative != filename || host.owner == user)) "Unsupported user secret path: ${projected.path}";
    assert lib.assertMsg (host.age.hostPubkey != null && host.age.storageMode == "local" && host.age.localStorageDir != null) "User secret refresh requires local host-rekeyed ciphertext";
    assert lib.assertMsg (sourcePath != null && builtins.pathExists sourcePath) "Missing user secret source: ${name}";
    assert lib.assertMsg (builtins.pathExists file) "Missing host-rekeyed user secret: ${file}; rekey and stage it first";
    lib.nameValuePair key {
      inherit file;
      name = relative;
      path = projected.path;
      mode = source.mode or "0400";
      group = source.group or "users";
      rekeyFile = null;
    }
  ) selected;
  hostBacked = selected != { };
  refreshEnabled = config.age.enable && hostBacked;
  refresh = pkgs.callPackage ../../pkg/home-age-refresh {
    username = user;
    secrets = builtins.attrValues secrets;
  };
in
if cfg-meta.isStandalone or false then {
  age.enable = lib.mkDefault hostBacked;
  age.secrets = lib.mkIf refreshEnabled (lib.mapAttrs (_: secret: builtins.removeAttrs secret [ "group" ]) secrets);
  age.identityPaths = lib.mkIf refreshEnabled [ "/etc/ssh/ssh_host_ed25519_key" ];
  systemd.user.services = lib.mkIf refreshEnabled { agenix.Install.WantedBy = lib.mkForce [ ]; };
  xdg.configFile = lib.mkIf refreshEnabled { "systemd/user/agenix.service".enable = lib.mkForce false; };
  launchd.agents = lib.mkIf refreshEnabled { activate-agenix.enable = lib.mkForce false; };
  home.extraBuilderCommands = lib.mkIf refreshEnabled ''
    ln -s ${lib.getExe refresh} "$out/refresh-user-secrets"
  '';
  age.rekey = {
    # agenix-rekey requires an identity even without secrets; reuse the
    # invalid placeholder from disabled system configurations.
    masterIdentities = lib.mkDefault [
      { identity = "/does-not-exist"; pubkey = "age"; }
    ];
    hostPubkey = lib.mkIf refreshEnabled host.age.hostPubkey;
    storageMode = lib.mkDefault "derivation";
    # See modules/nix-generic/age.nix: keep the merged rekey apps arch-neutral.
    agePlugins = lib.mkDefault [ ];
  };
} else {
  config = lib.mkMerge [
    # Always propagate hostPubkey and masterIdentities from the host projection.
    # hostPubkey suppresses agenix-rekey dummy-key warnings; real
    # masterIdentities satisfy agenix-rekey's non-empty assertion without
    # polluting the merged ageWrapper used by update-masterkeys.
    {
      age.rekey = lib.mkMerge [
        (lib.mkIf (host.age.hostPubkey != null) {
          hostPubkey = host.age.hostPubkey;
        })
        { masterIdentities = host.age.masterIdentities; }
        # See modules/nix-generic/age.nix: keep the merged rekey apps arch-neutral.
        { agePlugins = lib.mkDefault [ ]; }
      ];
    }

    (lib.mkIf (ageEnabled && host.age.storageMode != null) {
      age.rekey = {
        storageMode = host.age.storageMode;
        localStorageDir = host.age.localStorageDir;
      };
    })

    (lib.mkIf (!ageEnabled) {
      age.rekey.storageMode = "derivation";
    })
  ];
}
