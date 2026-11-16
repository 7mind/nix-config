{ flake, pkgs }:
let
  lib = pkgs.lib;
  fixtures = pkgs.runCommand "home-age-fixtures" {
    nativeBuildInputs = [ pkgs.age pkgs.openssh ];
  } ''
    mkdir -p "$out"
    ssh-keygen -q -t ed25519 -N "" -f "$out/host"
    cut -d ' ' -f 1-2 "$out/host.pub" | tr -d '\n' > "$out/recipient"
    age-keygen -o "$out/master" 2>/dev/null
    age-keygen -y "$out/master" > "$out/master.pub"
    age-keygen -o wrong-key 2>/dev/null
    wrong_pub=$(age-keygen -y wrong-key)
    pub_hash=$(sha256sum "$out/recipient" | cut -d ' ' -f 1)
    cat > "$out/age-secrets.nix" <<'EOF'
    { cfg-meta, owner, group }: builtins.listToAttrs (map (name: {
      inherit name;
      value = { rekeyFile = "''${cfg-meta.paths.secrets}/tester/''${name}.age"; inherit owner group; mode = "0440"; };
    }) [ "token" "second" ])
    EOF
    for variant in new rotated corrupt wrong missing partial; do
      root="$out/$variant/secrets"
      mkdir -p "$root/tester" "$root/rekeyed/fixture" "$root/rekeyed/fixture-tester"
      for name in token second; do
        printf '%s-%s\n' "$variant" "$name" | age -r "$(cat "$out/master.pub")" > "$root/tester/$name.age"
        source_hash=$(sha256sum "$root/tester/$name.age" | cut -d ' ' -f 1)
        hash=$(printf '%s' "$pub_hash$source_hash" | sha256sum | cut -c 1-32)
        file="$root/rekeyed/fixture/$hash-$name.age"
        age -d -i "$out/master" "$root/tester/$name.age" | age -r "$(cat "$out/recipient")" > "$file"
        if [[ $name == token ]]; then
          case "$variant" in
            corrupt) printf 'invalid age file\n' > "$file" ;;
            wrong) printf 'wrong recipient\n' | age -r "$wrong_pub" > "$file" ;;
          esac
        fi
        cp "$file" "$root/rekeyed/fixture-tester/"
        if [[ $variant == missing || ( $variant == partial && $name == token ) ]]; then rm "$file" "$root/rekeyed/fixture-tester/$(basename "$file")"; fi
      done
      cp "$out/age-secrets.nix" "$root/tester/age-secrets.nix"
    done
    for name in token second other root service; do
      printf 'old-%s\n' "$name" | age -r "$(cat "$out/recipient")" > "$out/system-$name.age"
    done
    head -c 33554432 /dev/zero | age -r "$(cat "$out/recipient")" > "$out/slow.age"
  '';
  homeFor = homePkgs: isLinux: owner: variant: extraModules: flake.inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = homePkgs;
    extraSpecialArgs.cfg-meta = {
      isStandalone = true;
      inherit isLinux;
      isDarwin = !isLinux;
      hostname = "fixture";
      paths.secrets = "${fixtures}/${variant}/secrets";
    };
    modules = [
      flake.inputs.agenix.homeManagerModules.default
      flake.inputs.agenix-rekey.homeManagerModules.default
      ../modules/hm/globals.nix
      ../modules/hm/age.nix
      {
        home = { username = "tester"; homeDirectory = "/home/tester"; stateVersion = "25.05"; };
        home.file.".hm-age-setting".text = variant;
        smind.hm.globals = {
          inherit owner;
          age = {
            enable = true;
            load-owner-secrets = true;
            hostPubkey = builtins.readFile "${fixtures}/recipient";
            storageMode = "local";
            localStorageDir = "${fixtures}/${variant}/secrets/rekeyed/fixture";
            masterIdentities = [ { identity = "/other-owner-key"; pubkey = "age-other-owner"; } ];
            secrets = builtins.listToAttrs (map (name: {
              name = (if owner == "tester" then "" else "tester/") + name;
              value = { owner = "tester"; path = "/run/agenix/" + (if owner == "tester" then "" else "tester/") + name; };
            }) [ "token" "second" ]) // {
              service = { owner = "tester"; path = "/run/agenix/service"; };
              root = { owner = "root"; path = "/run/agenix/root"; };
              other = { owner = "other"; path = "/run/agenix/other"; };
            };
          };
        };
      }
    ] ++ extraModules;
  };
  home = homeFor pkgs true;
  darwin = homeFor (import flake.inputs.nixpkgs { localSystem = "aarch64-darwin"; }) false "tester" "new" [ ];
  scoped = home "other" "new" [ ];
  legacy = home "tester" "new" [ ];
  rotated = home "other" "rotated" [ ];
  corrupt = home "other" "corrupt" [ ];
  wrong = home "other" "wrong" [ ];
  disabled = scoped.extendModules { modules = [ { age.enable = lib.mkForce false; } ]; };
  disabledMissingSource = home "other" "missing-source" [ { age.enable = lib.mkForce false; } ];
  disabledMissingCiphertext = home "other" "missing" [ { age.enable = lib.mkForce false; } ];
  empty = scoped.extendModules { modules = [ { smind.hm.globals.age.secrets = lib.mkForce { }; } ]; };
  precedence = legacy.extendModules { modules = [ {
    smind.hm.globals.age.secrets."tester/token" = { owner = "tester"; path = "/run/agenix/tester/token"; };
  } ]; };
  entryDisabled = scoped.extendModules { modules = [ { age.secrets."tester/token".enable = false; } ]; };
  restricted = scoped.extendModules { modules = [ { age.secrets."tester/token".mode = lib.mkForce "0400"; } ]; };
  effectiveEmpty = scoped.extendModules { modules = [ { age.secrets = lib.mkForce { }; } ]; };
  disableEntries = { age.secrets = builtins.listToAttrs (map (name: {
    name = "tester/${name}";
    value.enable = false;
  }) [ "token" "second" ]); };
  allDisabled = scoped.extendModules { modules = [ disableEntries ]; };
  allDisabledMissing = home "other" "missing" [ disableEntries ];
  disabledMissingEntry = home "other" "partial" [ { age.secrets."tester/token".enable = false; } ];
  overriddenFiles = home "other" "missing" [ {
    age.secrets = lib.mapAttrs (_: secret: { file = lib.mkForce secret.file; }) scoped.config.age.secrets;
  } ];
  renamed = scoped.extendModules { modules = [ { age.secrets."tester/token".path = lib.mkForce "/run/agenix/tester/renamed"; } ]; };
  invalidPath = path: scoped.extendModules { modules = [ { age.secrets."tester/token".path = lib.mkForce path; } ]; };
  invalidMode = mode: scoped.extendModules { modules = [ { age.secrets."tester/token".mode = lib.mkForce mode; } ]; };
  invalid = (map invalidPath [ "/tmp/token" "/run/agenix/other/token" "/run/agenix/token" "/run/agenix/tester/../root" "/run/agenix/tester/." "/run/agenix/tester/nested/token" ])
    ++ (map invalidMode [ "invalid" "u=rw" "04777" ])
    ++ [ (invalidPath "/run/agenix/tester/second") ];
  withoutSources = secrets: home "other" "missing-source" [ { smind.hm.globals.age.secrets = lib.mkForce secrets; } ];
  unowned = map withoutSources [
    { root = { owner = "root"; path = "/run/agenix/root"; }; }
    { service = { owner = "service"; path = "/run/agenix/service"; }; other = { owner = "other"; path = "/run/agenix/other"; }; }
    { "tester/token" = { owner = "tester"; path = "/run/agenix/tester/token"; enable = false; }; }
  ];
  check = profile: names:
    assert lib.assertMsg profile.config.age.enable "host-backed standalone age was disabled";
    assert lib.assertMsg (builtins.attrNames profile.config.age.secrets == names) "standalone age did not select only source-defined user secrets";
    assert lib.assertMsg (builtins.all (s: s.rekeyFile == null && builtins.pathExists s.file && s.path == "/run/agenix/${s.name}") (builtins.attrValues profile.config.age.secrets)) "standalone age must use existing host ciphertext and paths";
    assert lib.assertMsg (!profile.config.xdg.configFile."systemd/user/agenix.service".enable && profile.config.systemd.user.services.agenix.Install.WantedBy == [ ] && !profile.config.launchd.agents.activate-agenix.enable) "runtime-only age must not start a stock user service";
    assert lib.assertMsg (profile.config.age.rekey.masterIdentities == [ { identity = "/does-not-exist"; pubkey = "age"; } ]) "runtime-only age must not inherit another user's master identity";
    true;
  rekeyableFor = extraModules: flake.inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs.cfg-meta = { isStandalone = true; isLinux = true; isDarwin = false; paths.secrets = "/missing-native-secrets"; };
    modules = [
      flake.inputs.agenix.homeManagerModules.default
      flake.inputs.agenix-rekey.homeManagerModules.default
      ../modules/hm/globals.nix
      {
        home = { username = "rekeyable"; homeDirectory = "/home/rekeyable"; stateVersion = "25.05"; };
        age.enable = true;
        age.rekey = {
          storageMode = "local";
          localStorageDir = "${fixtures}/new/secrets/rekeyed/fixture";
          hostPubkey = builtins.readFile "${fixtures}/recipient";
          masterIdentities = [ { identity = "${fixtures}/master"; pubkey = lib.removeSuffix "\n" (builtins.readFile "${fixtures}/master.pub"); } ];
          agePlugins = [ ];
        };
        age.secrets.token.rekeyFile = "${fixtures}/new/secrets/tester/token.age";
      }
    ] ++ extraModules;
  };
  rekeyable = rekeyableFor [ ../modules/hm/age.nix ];
  foreign = rekeyableFor [ ];
  aggregate = homes: (import ../lib/mk-flake.nix {
    inputs = flake.inputs;
    self = { outPath = toString fixtures; nixosConfigurations = { }; darwinConfigurations = { }; homeConfigurations = homes; };
  }).agenix-rekey.${pkgs.stdenv.hostPlatform.system};
  withoutRuntime = aggregate { inherit rekeyable; };
  withRuntime = aggregate { inherit rekeyable; runtime = scoped; };
  runtimeOnly = aggregate { runtime = scoped; };
  missingRuntime = aggregate { inherit rekeyable; runtime = home "other" "missing" [ ]; };
  foreignRuntime = aggregate { rekeyable = foreign; runtime = home "other" "missing" [ ]; };
  switch = profile: import ../lib/home-switch.nix { inherit pkgs; home = profile; };
  noAgeArtifacts = profile: ''
    test ${lib.boolToString (profile.config.systemd.user.services ? agenix)} = false
    test ${lib.boolToString (profile.config.xdg.configFile ? "systemd/user/agenix.service")} = false
    test ${lib.boolToString (profile.config.launchd.agents ? activate-agenix)} = false
    test ! -e ${profile.activationPackage}/home-files/.config/systemd/user/agenix.service
  '';
in
assert check scoped [ "tester/second" "tester/token" ];
assert check legacy [ "second" "token" ];
assert lib.assertMsg (builtins.attrNames precedence.config.age.secrets == [ "second" "tester/token" ]) "scoped secrets must take precedence over legacy owner names";
assert lib.assertMsg (!empty.config.age.enable && empty.config.age.secrets == { }) "empty host age must remain disabled";
assert lib.assertMsg (!(builtins.tryEval (builtins.deepSeq (home "other" "missing" [ ]).config.age.secrets true)).success) "missing selected ciphertext must fail evaluation";
assert lib.assertMsg (!(builtins.tryEval (builtins.deepSeq (home "other" "missing-source" [ ]).config.age.secrets true)).success) "missing enabled source definitions must fail evaluation";
assert lib.assertMsg (rekeyable.config.xdg.configFile."systemd/user/agenix.service".enable && rekeyable.config.age.identityPaths == [ "/home/rekeyable/.ssh/id_ed25519" "/home/rekeyable/.ssh/id_rsa" ]) "native standalone age behavior must remain intact";
assert lib.assertMsg (withoutRuntime.edit-view.drvPath == withRuntime.edit-view.drvPath && withoutRuntime.update-masterkeys.drvPath == withRuntime.update-masterkeys.drvPath) "runtime-only homes poisoned aggregate rekey identities or recipients";
assert lib.assertMsg (runtimeOnly.edit-view.drvPath != withRuntime.edit-view.drvPath) "explicitly rekeyable homes must contribute their identities and sources";
pkgs.runCommand "home-age" {
  nativeBuildInputs = [ pkgs.age pkgs.gnugrep ];
  passthru = {
    inherit fixtures scoped legacy rotated corrupt wrong switch disabledMissingSource disabledMissingCiphertext;
    inherit entryDisabled restricted effectiveEmpty allDisabled allDisabledMissing disabledMissingEntry overriddenFiles renamed unowned missingRuntime withoutRuntime;
  };
} ''
  ${noAgeArtifacts disabledMissingSource}
  ${noAgeArtifacts disabledMissingCiphertext}
  test ${lib.boolToString disabledMissingSource.config.smind.hm.age.runtimeOnly} = false
  test ${lib.boolToString disabledMissingCiphertext.config.smind.hm.age.runtimeOnly} = false
  ${noAgeArtifacts empty}
  test ${lib.boolToString (withoutRuntime.edit-view.drvPath == missingRuntime.edit-view.drvPath && withoutRuntime.update-masterkeys.drvPath == missingRuntime.update-masterkeys.drvPath)} = true
  test ${lib.boolToString (withoutRuntime.edit-view.drvPath == foreignRuntime.edit-view.drvPath && withoutRuntime.update-masterkeys.drvPath == foreignRuntime.update-masterkeys.drvPath)} = true
  ${lib.concatMapStrings (profile: ''
    test ! -e ${profile.activationPackage}/refresh-user-secrets
    test ${lib.boolToString profile.config.xdg.configFile."systemd/user/agenix.service".enable} = false
  '') [ effectiveEmpty allDisabled allDisabledMissing ]}
  ${lib.concatMapStrings (profile: ''
    test ${lib.boolToString profile.config.age.enable} = false
    test ! -e ${profile.activationPackage}/refresh-user-secrets
  '') unowned}
  test ${lib.boolToString (builtins.all (profile: !(builtins.tryEval (builtins.deepSeq profile.config.home.extraBuilderCommands true)).success) invalid)} = true
  test -x ${disabledMissingEntry.activationPackage}/refresh-user-secrets
  test -x ${overriddenFiles.activationPackage}/refresh-user-secrets
  test ${lib.boolToString (darwin.config.launchd.agents ? activate-agenix)} = false
  test ${lib.boolToString (darwin.config.systemd.user.services ? agenix)} = false
  test ${lib.boolToString (darwin.config.xdg.configFile ? "systemd/user/agenix.service")} = false
  test -x ${scoped.activationPackage}/refresh-user-secrets
  test -x ${legacy.activationPackage}/refresh-user-secrets
  test ! -e ${disabled.activationPackage}/refresh-user-secrets
  test ! -e ${disabledMissingSource.activationPackage}/refresh-user-secrets
  test ! -e ${disabledMissingCiphertext.activationPackage}/refresh-user-secrets
  test ! -e ${empty.activationPackage}/refresh-user-secrets
  test ! -e ${rekeyable.activationPackage}/refresh-user-secrets
  wrapper=$(grep -Eo '/nix/store/[^ ]+/bin/ageWrapper' ${missingRuntime.edit-view}/bin/agenix-edit-view | head -1)
  ! grep -F -- /does-not-exist "$wrapper"
  ! grep -E -- "-r '?age'?([[:space:]]|$)" "$wrapper"
  grep -F -- '${fixtures}/master' "$wrapper"
  mkdir checkout
  cd checkout
  touch flake.nix
  cp -r ${fixtures}/new .
  chmod -R u+w new
  ${missingRuntime.update-masterkeys}/bin/agenix-update-masterkeys
  age -d -i ${fixtures}/master new/secrets/tester/token.age | grep -Fx new-token
  printf 'edited\n' > input
  ${missingRuntime.edit-view}/bin/agenix-edit-view edit -i input created.age
  age -d -i ${fixtures}/master created.age | grep -Fx edited
  touch "$out"
''
