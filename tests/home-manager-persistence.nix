{ flake, pkgs }:
let
  home = label: { lib, ... }: {
    home.stateVersion = "25.05";
    home.file.".hm-test-setting".text = label;
    home.file.".hm-test-new-only" = lib.mkIf (label == "failing") { text = label; };
    home.packages = [ (pkgs.writeShellScriptBin "hm-fixture-tool" "echo ${label}") ];
    home.activation.intentionalFailure = lib.mkIf (label == "failing")
      (lib.hm.dag.entryAfter [ "linkGeneration" ] "exit 17");
  };
  standalone = label: flake.inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [ (home label) { home = { username = "tester"; homeDirectory = "/home/tester"; }; } ];
  };
  switch = label: import ../lib/home-switch.nix { inherit pkgs; home = standalone label; };
in
pkgs.testers.runNixOSTest {
  name = "home-manager-persistence";
  nodes.machine = { lib, ... }: {
    imports = [ flake.inputs.home-manager.nixosModules.home-manager
      ../modules/nix-generic/home-manager.nix ../modules/nixos/home-manager.nix ];
    _module.args.specialArgsSelfRef.cfg-hm-modules = [ ];
    smind.home-manager.enable = true;
    boot.loader.grub.enable = false;
    virtualisation.additionalPaths = [ (switch "new") (switch "failing") ];
    users.users.homealias = { name = "tester"; isNormalUser = true; packages = [ pkgs.hello ]; };
    home-manager.users.homealias = home "old";
    specialisation.new.configuration.home-manager.users.homealias = lib.mkForce (home "new");
  };
  testScript = ''
    unit = "home-manager-tester.service"
    def check(label):
        machine.succeed(f"grep -Fx {label} /home/tester/.hm-test-setting",
                        f"test $(/etc/profiles/per-user/tester/bin/hm-fixture-tool) = {label}",
                        "/etc/profiles/per-user-system/tester/bin/hello")
    machine.start(allow_reboot=True)
    machine.wait_for_unit(unit)
    system = machine.succeed("readlink -f /run/current-system").strip()
    check("old")
    apply = "runuser -u tester -- ${switch "new"}/bin/switch-home /etc/smind/home-manager /etc/NIXOS"
    machine.fail("runuser -u tester -- ${switch "new"}/bin/switch-home /missing /etc/NIXOS")
    for command, label in [
        (apply, "new"), ("systemctl restart " + unit, "new"), ("reboot", "new"),
        (system + "/bin/switch-to-configuration switch", "old"),
        (apply, "new"), ("systemctl restart " + unit, "new"),
        (system + "/specialisation/new/bin/switch-to-configuration switch", "new"),
        ("reboot", "old"),
        (system + "/bin/switch-to-configuration switch", "old"),
    ]:
        if command == "reboot":
            machine.reboot()
        else:
            machine.succeed(command)
        machine.wait_for_unit(unit)
        check(label)
    assert machine.execute("runuser -u tester -- ${switch "failing"}/bin/switch-home /etc/smind/home-manager /etc/NIXOS")[0] == 17
    check("failing")
    machine.succeed("grep -Fx failing /home/tester/.hm-test-new-only")
    machine.reboot()
    machine.wait_until_succeeds("systemctl is-failed " + unit)
    check("failing")
  '';
}
