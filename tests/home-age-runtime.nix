{ flake, pkgs }:
let
  lib = pkgs.lib;
  evaluation = import ./home-age.nix { inherit flake pkgs; };
  inherit (evaluation) fixtures scoped legacy rotated corrupt wrong switch entryDisabled restricted renamed;
  inherit (evaluation) disabledMissingEntry overriddenFiles effectiveEmpty allDisabled allDisabledMissing contextlessManifest;
  apply = profile: "runuser -u tester -- ${switch profile}/bin/switch-home /etc/smind/home-manager /etc/NIXOS";
  manifest = secrets: pkgs.callPackage ../pkg/home-age-refresh/manifest.nix { inherit secrets; };
  secret = path: file: { inherit path file; group = "users"; mode = "0440"; };
  token = scoped.config.age.secrets."tester/token".file;
  slow = manifest [ (secret "/run/agenix/tester/token" "${fixtures}/slow.age") ];
  outside = manifest [ (secret "/run/agenix/../outside" token) ];
  otherUser = manifest [ (secret "/run/agenix/other/token" token) ];
  invalidManifest = pkgs.writeText "invalid-home-age.json" ''[{"file":"/etc/passwd","destination":"tester/token","group":"users","mode":"0440"}]'';
  rootSecret = manifest [ (secret "/run/agenix/root" token) ];
  helper = lib.getExe (pkgs.callPackage ../pkg/home-age-refresh { });
  asUser = user: data: "runuser -u ${user} -- /run/wrappers/bin/sudo -n -- ${helper} < ${data}";
  direct = asUser "tester";
  refresh = profile: direct "${profile.activationPackage}/refresh-user-secrets.json";
  restore = manifest (map (name: secret "/run/agenix/tester/${name}" "${fixtures}/system-${name}.age") [ "token" "second" ]);
  badGroup = manifest [ ((secret "/run/agenix/tester/token" token) // { group = "missing-refresh-group"; }) ];
  duplicate = manifest (builtins.genList (_: secret "/run/agenix/tester/token" token) 2);
in
pkgs.testers.runNixOSTest {
  name = "home-age-runtime";
  nodes.machine = { lib, ... }: {
    imports = [
      flake.inputs.home-manager.nixosModules.home-manager
      flake.inputs.agenix.nixosModules.default
      ../modules/nix-generic/home-manager.nix
      ../modules/nixos/home-manager.nix
      ../modules/nixos/sudo.nix
    ];
    _module.args.specialArgsSelfRef.cfg-hm-modules = [ ];
    smind.home-manager.enable = true;
    boot.loader.grub.enable = false;
    system.switch.enable = true;
    systemd.sysusers.enable = lib.mkForce false;
    users.users = {
      tester = { isNormalUser = true; uid = 1000; extraGroups = [ "wheel" ]; };
      other = { isNormalUser = true; uid = 1001; extraGroups = [ "wheel" ]; };
      denied = { isNormalUser = true; uid = 1002; };
    };
    smind.security.sudo.wheel-permissive-rules = true;
    home-manager.users.tester = {
      home.stateVersion = "25.05";
      home.file.".hm-age-setting".text = "old";
    };
    environment.etc."smind/home-manager/denied".text = "/home/denied/unused-profile\n";
    virtualisation.additionalPaths = [
      evaluation (switch scoped) (switch legacy) (switch rotated) (switch corrupt) (switch wrong)
      entryDisabled.activationPackage restricted.activationPackage renamed.activationPackage
      disabledMissingEntry.activationPackage overriddenFiles.activationPackage
      effectiveEmpty.activationPackage allDisabled.activationPackage allDisabledMissing.activationPackage
      slow outside otherUser rootSecret restore badGroup duplicate contextlessManifest invalidManifest
    ];
    system.activationScripts.testHostKey = {
      deps = [ "specialfs" ];
      text = "install -D -m0600 ${fixtures}/host /etc/ssh/ssh_host_ed25519_key";
    };
    system.activationScripts.agenixInstall.deps = [ "testHostKey" ];
    age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    age.secrets = builtins.listToAttrs (map (name: {
      inherit name;
      value = {
        file = "${fixtures}/system-${if name == "other-sentinel" then "other" else builtins.baseNameOf name}.age";
        owner = if name == "other-sentinel" then "other" else if name == "root" then "root" else "tester";
        group = "users";
        mode = "0440";
      };
    }) [ "tester/token" "tester/second" "token" "second" "other-sentinel" "root" "service" ]);
  };
  testScript = ''
    machine.start(allow_reboot=True)
    machine.wait_for_unit("home-manager-tester.service")
    system = machine.succeed("readlink -f /run/current-system").strip()
    generation = machine.succeed("readlink /run/agenix").strip()
    profile = "/nix/var/nix/profiles/smind-home/tester/generation"
    sentinels = "sha256sum /run/agenix/{other-sentinel,root,service}; stat -c '%n %u %g %a %i %Y' /run/agenix/{other-sentinel,root,service}"
    initial_sentinels = machine.succeed(sentinels)

    def check(label, prefix):
        machine.succeed(f"grep -Fx {label}-token /run/agenix/{prefix}token",
                        f"grep -Fx {label}-second /run/agenix/{prefix}second",
                        f"test $(stat -c %u:%g:%a /run/agenix/{prefix}token) = 1000:100:440",
                        "test $(stat -c %u /run/agenix) = 0",
                        "test $(stat -c %u:%a /run/agenix.d) = 0:751",
                        f"test $(stat -c %u:%a {generation}) = 0:751",
                        f"test $(stat -c %u {generation}/tester) = 0",
                        f"test -z \"$(find {generation} -maxdepth 1 -name '.hm-age.*' -print)\"")
        assert machine.succeed(sentinels) == initial_sentinels
        assert machine.succeed("readlink /run/agenix").strip() == generation

    def failed(command):
        before = machine.succeed(f"readlink -f {profile}; cat /home/tester/.hm-age-setting; sha256sum /run/agenix/tester/{{token,second}}")
        machine.fail(command)
        assert machine.succeed(f"readlink -f {profile}; cat /home/tester/.hm-age-setting; sha256sum /run/agenix/tester/{{token,second}}") == before
        check("rotated", "tester/")

    with subtest("refresh uses packaged ciphertext when its original source is unavailable"):
        machine.succeed("mkdir /run/hidden-ciphertext; mount --bind /run/hidden-ciphertext ${fixtures}")
        try:
            machine.succeed("${direct contextlessManifest}")
            check("new", "tester/")
        finally:
            machine.succeed("umount ${fixtures}")
    machine.succeed("${direct restore}")

    with subtest("first current-user namespace is created after successful decryption"):
        machine.succeed("mv /run/agenix/tester /run/agenix/held-tester")
        try:
            machine.succeed("${apply scoped}", "test $(stat -c %u:%g:%a /run/agenix/tester) = 0:0:755")
            check("new", "tester/")
        finally:
            machine.succeed("rm -rf /run/agenix/tester; mv /run/agenix/held-tester /run/agenix/tester")

    with subtest("effective per-entry disable preserves the destination"):
        token = machine.succeed("sha256sum /run/agenix/tester/token; stat -c '%u:%g:%a:%i:%Y' /run/agenix/tester/token")
        machine.succeed("${refresh entryDisabled}")
        assert machine.succeed("sha256sum /run/agenix/tester/token; stat -c '%u:%g:%a:%i:%Y' /run/agenix/tester/token") == token
        machine.succeed("grep -Fx new-second /run/agenix/tester/second")
    machine.succeed("${direct restore}")

    with subtest("disabled missing ciphertext is not consumed"):
        token = machine.succeed("sha256sum /run/agenix/tester/token; stat -c '%u:%g:%a:%i:%Y' /run/agenix/tester/token")
        machine.succeed("${refresh disabledMissingEntry}", "grep -Fx partial-second /run/agenix/tester/second")
        assert machine.succeed("sha256sum /run/agenix/tester/token; stat -c '%u:%g:%a:%i:%Y' /run/agenix/tester/token") == token
    machine.succeed("${direct restore}")

    with subtest("effective file override does not consume absent default ciphertext"):
        machine.succeed("${refresh overriddenFiles}")
        check("new", "tester/")
    machine.succeed("${direct restore}")

    with subtest("empty and disabled effective sets do not attach a manifest"):
        for activation in ["${effectiveEmpty.activationPackage}", "${allDisabled.activationPackage}", "${allDisabledMissing.activationPackage}"]:
            machine.succeed(f"test ! -e {activation}/refresh-user-secrets.json")

    with subtest("effective restrictive mode controls publication"):
        machine.succeed("${refresh restricted}", "test $(stat -c %a /run/agenix/tester/token) = 400")
    machine.succeed("${direct restore}")

    with subtest("effective safe path override preserves the old destination"):
        token = machine.succeed("sha256sum /run/agenix/tester/token; stat -c '%u:%g:%a:%i:%Y' /run/agenix/tester/token")
        machine.succeed("${refresh renamed}", "grep -Fx new-token /run/agenix/tester/renamed")
        assert machine.succeed("sha256sum /run/agenix/tester/token; stat -c '%u:%g:%a:%i:%Y' /run/agenix/tester/token") == token
    machine.succeed("${direct restore}")

    with subtest("failed decryptions and permissions do not create a namespace"):
        machine.succeed("mv /run/agenix/tester /run/agenix/held-tester")
        before = machine.succeed(f"readlink -f {profile}; cat /home/tester/.hm-age-setting; stat -c '%n %u %g %a' /run/agenix.d {generation}")
        try:
            for command, phase in [("${apply corrupt}", "decryption"), ("${apply wrong}", "decryption"), ("${direct badGroup}", "permissions")]:
                status, output = machine.execute(command + " 2>&1")
                assert status != 0, output
                assert f"failed during {phase}" in output, output
                machine.succeed("test ! -e /run/agenix/tester", f"test -z \"$(find {generation} -maxdepth 1 -name '.hm-age.*' -print)\"")
                assert machine.succeed(f"readlink -f {profile}; cat /home/tester/.hm-age-setting; stat -c '%n %u %g %a' /run/agenix.d {generation}") == before
                assert machine.succeed(sentinels) == initial_sentinels
        finally:
            machine.succeed("mv /run/agenix/held-tester /run/agenix/tester")

    with subtest("namespace files and dangling symlinks are rejected without mutation"):
        machine.succeed("mv /run/agenix/tester /run/agenix/held-tester")
        try:
            for create in ["touch /run/agenix/tester", "ln -s absent /run/agenix/tester"]:
                machine.succeed(create)
                before = machine.succeed("stat -c '%u:%g:%a:%i:%F' /run/agenix/tester")
                machine.fail("${apply scoped}")
                assert machine.succeed("stat -c '%u:%g:%a:%i:%F' /run/agenix/tester") == before
                machine.succeed("rm /run/agenix/tester", "test ! -e /run/agenix/absent")
                assert machine.succeed(sentinels) == initial_sentinels
        finally:
            machine.succeed("rm -f /run/agenix/tester; mv /run/agenix/held-tester /run/agenix/tester")

    with subtest("duplicate destinations fail before publication"):
        token = machine.succeed("sha256sum /run/agenix/tester/token; stat -c '%u:%g:%a:%i:%Y' /run/agenix/tester/token")
        machine.fail("${direct duplicate}")
        assert machine.succeed("sha256sum /run/agenix/tester/token; stat -c '%u:%g:%a:%i:%Y' /run/agenix/tester/token") == token
    machine.succeed("${direct restore}")

    check("old", "tester/")
    with subtest("two wheel users share the same passwordless helper"):
        machine.succeed("${asUser "other" otherUser}",
                        "grep -Fx new-token /run/agenix/other/token",
                        "test $(stat -c %u:%g:%a /run/agenix/other/token) = 1001:100:440")
        machine.fail("${asUser "denied" otherUser}")
        machine.fail("${asUser "other" contextlessManifest}")
        check("old", "tester/")
    machine.succeed("${apply scoped}")
    check("new", "tester/")
    machine.succeed("grep -Fx old-token /run/agenix/token", "grep -Fx new /home/tester/.hm-age-setting",
                    "test ! -e /home/tester/.config/systemd/user/agenix.service")
    machine.succeed("${apply scoped}", "${apply legacy}")
    check("new", "")
    machine.succeed("${apply rotated}")
    check("rotated", "tester/")
    assert machine.succeed("readlink -f /run/current-system").strip() == system
    failed("${apply corrupt}")
    failed("${apply wrong}")
    failed("setsid runuser -u denied -- ${switch scoped}/bin/switch-home /etc/smind/home-manager /etc/NIXOS < /dev/null")
    failed("${direct outside}")
    failed("${direct invalidManifest}")
    failed("${direct otherUser}")
    failed("${direct rootSecret}")
    machine.succeed("mv /etc/ssh/ssh_host_ed25519_key /etc/ssh/held")
    failed("${apply scoped}")
    machine.succeed("mv /etc/ssh/held /etc/ssh/ssh_host_ed25519_key")
    machine.succeed("mv /run/agenix/tester/token /run/agenix/tester/held; ln -s ../root /run/agenix/tester/token")
    machine.fail("${apply scoped}")
    machine.succeed("rm /run/agenix/tester/token; mv /run/agenix/tester/held /run/agenix/tester/token")
    check("rotated", "tester/")
    machine.succeed("chown root /run/agenix/tester/token")
    machine.fail("${apply scoped}")
    machine.succeed("chown tester /run/agenix/tester/token")
    machine.succeed("mv /run/agenix/tester /run/agenix/held; ln -s held /run/agenix/tester")
    machine.fail("${apply scoped}")
    machine.succeed("rm /run/agenix/tester; mv /run/agenix/held /run/agenix/tester")
    machine.succeed("chmod 0777 /run/agenix/tester")
    machine.fail("${apply scoped}")
    machine.succeed("chmod 0755 /run/agenix/tester", "chown tester /run/agenix/tester")
    machine.fail("${apply scoped}")
    machine.succeed("chown root /run/agenix/tester")
    machine.succeed(f"ln -s /run/agenix.d /run/agenixXd; ln -sfn /run/agenixXd/{generation.rsplit('/', 1)[1]} /run/agenix")
    machine.fail("${apply scoped}")
    machine.succeed(f"ln -sfn {generation} /run/agenix; rm /run/agenixXd")
    check("rotated", "tester/")
    machine.succeed("( setsid ${direct slow} > /run/slow.log 2>&1 & "
                    "for n in $(seq 1 1000); do "
                    f"if compgen -G '{generation}/.hm-age.*' > /dev/null; then "
                    "pid=$(pgrep -f '^${pkgs.runtimeShell} ${helper}$'); "
                    "kill -STOP $pid; echo $pid > /run/slow.pid; exit 0; fi; sleep 0.01; done; exit 1 )", timeout=30)
    selected_profile = machine.succeed(f"readlink -f {profile}")
    machine.fail("${apply scoped}")
    assert machine.succeed(f"readlink -f {profile}") == selected_profile
    machine.fail(system + "/bin/switch-to-configuration switch")
    assert machine.succeed("readlink /run/agenix").strip() == generation
    machine.succeed("kill -TERM $(cat /run/slow.pid); kill -CONT $(cat /run/slow.pid)")
    machine.wait_until_succeeds(f"test -z \"$(find {generation} -maxdepth 1 -name '.hm-age.*' -print)\"")
    check("rotated", "tester/")
    machine.succeed("${apply scoped}")
    check("new", "tester/")
    machine.succeed(system + "/bin/switch-to-configuration switch")
    machine.succeed("grep -Fx old-token /run/agenix/tester/token", "grep -Fx new /home/tester/.hm-age-setting")
    machine.succeed("${apply rotated}")
    machine.reboot()
    machine.wait_for_unit("home-manager-tester.service")
    machine.succeed("grep -Fx old-token /run/agenix/tester/token", "grep -Fx rotated /home/tester/.hm-age-setting")
  '';
}
