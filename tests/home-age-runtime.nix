{ flake, pkgs }:
let
  lib = pkgs.lib;
  evaluation = import ./home-age.nix { inherit flake pkgs; };
  inherit (evaluation) fixtures scoped legacy rotated corrupt wrong switch;
  apply = profile: "runuser -u tester -- ${switch profile}/bin/switch-home /etc/smind/home-manager /etc/NIXOS";
  helper = path: file: pkgs.callPackage ../pkg/home-age-refresh {
    username = "tester";
    secrets = [ { inherit path file; group = "users"; mode = "0440"; } ];
  };
  slow = helper "/run/agenix/tester/token" "${fixtures}/slow.age";
  outside = helper "/run/agenix/../outside" scoped.config.age.secrets."tester/token".file;
  otherUser = helper "/run/agenix/other/token" scoped.config.age.secrets."tester/token".file;
  rootSecret = helper "/run/agenix/root" scoped.config.age.secrets."tester/token".file;
  direct = package: "runuser -u tester -- /run/wrappers/bin/sudo -- ${lib.getExe package}";
in
pkgs.testers.runNixOSTest {
  name = "home-age-runtime";
  nodes.machine = { lib, ... }: {
    imports = [
      flake.inputs.home-manager.nixosModules.home-manager
      flake.inputs.agenix.nixosModules.default
      ../modules/nix-generic/home-manager.nix
      ../modules/nixos/home-manager.nix
    ];
    _module.args.specialArgsSelfRef.cfg-hm-modules = [ ];
    smind.home-manager.enable = true;
    boot.loader.grub.enable = false;
    system.switch.enable = true;
    systemd.sysusers.enable = lib.mkForce false;
    users.users = {
      tester = { isNormalUser = true; uid = 1000; extraGroups = [ "wheel" ]; };
      other = { isNormalUser = true; uid = 1001; };
      denied = { isNormalUser = true; uid = 1002; };
    };
    security.sudo.wheelNeedsPassword = false;
    home-manager.users.tester = {
      home.stateVersion = "25.05";
      home.file.".hm-age-setting".text = "old";
    };
    environment.etc."smind/home-manager/denied".text = "/home/denied/unused-profile\n";
    virtualisation.additionalPaths = [
      evaluation (switch scoped) (switch legacy) (switch rotated) (switch corrupt) (switch wrong)
      slow outside otherUser rootSecret
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
        file = "${fixtures}/system-${builtins.baseNameOf name}.age";
        owner = if name == "other" then "other" else if name == "root" then "root" else "tester";
        group = "users";
        mode = "0440";
      };
    }) [ "tester/token" "tester/second" "token" "second" "other" "root" "service" ]);
  };
  testScript = ''
    machine.start(allow_reboot=True)
    machine.wait_for_unit("home-manager-tester.service")
    system = machine.succeed("readlink -f /run/current-system").strip()
    generation = machine.succeed("readlink /run/agenix").strip()
    profile = "/nix/var/nix/profiles/smind-home/tester/generation"
    sentinels = "sha256sum /run/agenix/{other,root,service}; stat -c '%n %u %g %a %i %Y' /run/agenix/{other,root,service}"
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
    machine.succeed("( setsid ${direct slow} < /dev/null > /run/slow.log 2>&1 & "
                    "for n in $(seq 1 1000); do "
                    f"if compgen -G '{generation}/.hm-age.*' > /dev/null; then "
                    "pid=$(pgrep -f '^${pkgs.runtimeShell} ${lib.getExe slow}$'); "
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
