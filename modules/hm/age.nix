{ config, lib, pkgs, cfg-meta, ... }:

let
  host = config.smind.hm.globals;
  ageEnabled = host.age.enable;
  user = config.home.username;
  sourceFile = "${cfg-meta.paths.secrets}/${user}/age-secrets.nix";
  owned = lib.filterAttrs (_: secret: (secret.enable or true) && secret.owner == user) host.age.secrets;
  sources = if cfg-meta.isLinux && ageEnabled && owned != { } then
    assert lib.assertMsg (builtins.pathExists sourceFile) "Missing user secret definitions: ${sourceFile}";
    import sourceFile { inherit cfg-meta; owner = user; group = "users"; }
    else { };
  projectedName = name: if builtins.hasAttr "${user}/${name}" host.age.secrets then "${user}/${name}" else name;
  selected = lib.filterAttrs (name: source:
    let projected = owned.${projectedName name} or null;
    in projected != null && (source.enable or true) && (source.owner or user) == user
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
    lib.nameValuePair key {
      file = lib.mkDefault (
        assert lib.assertMsg (safeFilename filename) "Unsupported user secret name: ${filename}";
        assert lib.assertMsg (host.age.hostPubkey != null && host.age.storageMode == "local" && host.age.localStorageDir != null) "User secret refresh requires local host-rekeyed ciphertext";
        assert lib.assertMsg (sourcePath != null && builtins.pathExists sourcePath) "Missing user secret source: ${name}";
        assert lib.assertMsg (builtins.pathExists file) "Missing host-rekeyed user secret: ${file}; rekey and stage it first";
        file
      );
      name = relative;
      path = projected.path;
      mode = source.mode or "0400";
      group = source.group or "users";
      rekeyFile = null;
    }
  ) selected;
  hostBacked = selected != { };
  runtimeOnly = config.age.enable && hostBacked;
  effective = lib.filterAttrs (name: secret: builtins.hasAttr name secrets && secret.enable) config.age.secrets;
  safeFilename = name: name != "." && name != ".." && builtins.match "[a-zA-Z0-9_.-]+" name != null;
  manifest =
    let paths = map (secret: secret.path) (builtins.attrValues effective);
    in
    assert lib.assertMsg (builtins.length paths == builtins.length (lib.unique paths)) "Duplicate user secret refresh destinations";
    lib.mapAttrsToList (name: secret:
      let
        relative = lib.removePrefix "/run/agenix/" secret.path;
        scoped = lib.hasPrefix "${user}/" relative;
        filename = if scoped then lib.removePrefix "${user}/" relative else relative;
      in
      assert lib.assertMsg (lib.hasPrefix "/run/agenix/" secret.path && (scoped || host.owner == user) && safeFilename filename) "Unsupported user secret path: ${secret.path}";
      assert lib.assertMsg (builtins.match "0?[0-7]{3}" secret.mode != null) "Unsupported user secret mode: ${secret.mode}";
      assert lib.assertMsg (builtins.pathExists secret.file) "Missing user secret ciphertext: ${toString secret.file}";
      {
        inherit (secret) file path mode;
        inherit (secrets.${name}) group;
      }
    ) effective;
  refreshEnabled = runtimeOnly && effective != { };
  refreshManifest = pkgs.callPackage ../../pkg/home-age-refresh/manifest.nix { secrets = manifest; };
in
if cfg-meta.isStandalone or false then {
  options.smind.hm.age.runtimeOnly = lib.mkOption {
    type = lib.types.bool;
    internal = true;
    readOnly = true;
    description = "Whether host-backed secrets use the privileged runtime refresh instead of native Home Manager age.";
  };
  config = {
    smind.hm.age.runtimeOnly = runtimeOnly;
    age.enable = lib.mkDefault hostBacked;
    age.secrets = lib.mkIf runtimeOnly (lib.mapAttrs (_: secret: builtins.removeAttrs secret [ "group" ]) secrets);
    age.identityPaths = lib.mkIf runtimeOnly [ "/etc/ssh/ssh_host_ed25519_key" ];
    systemd.user.services = lib.mkIf runtimeOnly { agenix.Install.WantedBy = lib.mkForce [ ]; };
    xdg.configFile = lib.mkIf runtimeOnly { "systemd/user/agenix.service".enable = lib.mkForce false; };
    launchd.agents = lib.mkIf runtimeOnly { activate-agenix.enable = lib.mkForce false; };
    home.extraBuilderCommands = lib.mkIf refreshEnabled ''
      ln -s ${refreshManifest} "$out/refresh-user-secrets.json"
    '';
    age.rekey = {
      # agenix-rekey requires an identity even without secrets; reuse the
      # invalid placeholder from disabled system configurations.
      masterIdentities = lib.mkDefault [
        { identity = "/does-not-exist"; pubkey = "age"; }
      ];
      hostPubkey = lib.mkIf runtimeOnly host.age.hostPubkey;
      storageMode = lib.mkDefault "derivation";
      # See modules/nix-generic/age.nix: keep the merged rekey apps arch-neutral.
      agePlugins = lib.mkDefault [ ];
    };
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
