{ projectPath, username, homeDirectory }:
let
  flake = builtins.getFlake "git+file://${projectPath}?submodules=1";
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  home = label: flake.inputs.home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [ ({ lib, ... }: {
      home = {
        inherit username homeDirectory;
        stateVersion = "25.05";
        file.".hm-test-setting".text = label;
        file.".hm-test-new-only" = lib.mkIf (label == "failing") { text = label; };
        packages = [ (pkgs.writeShellScriptBin "hm-fixture-tool" "echo ${label}") ];
      };
      home.activation.intentionalFailure = lib.mkIf (label == "failing")
        (lib.hm.dag.entryAfter [ "linkGeneration" ] "exit 17");
    }) ];
  };
  activation = label: import ../lib/standalone-home-activation.nix { inherit pkgs; home = home label; };
  alias = flake.inputs.nixpkgs.lib.nixosSystem {
    system = builtins.currentSystem;
    specialArgs.specialArgsSelfRef = { cfg-hm-modules = [ ]; };
    modules = [
      flake.inputs.home-manager.nixosModules.home-manager
      ../modules/nix-generic/home-manager.nix
      ../modules/nixos/home-manager.nix
      {
        smind.home-manager.enable = true;
        system.stateVersion = "25.05";
        users.users.homealias = {
          name = "runtimeuser";
          isNormalUser = true;
          home = "/home/runtimeuser";
        };
        home-manager.users.homealias.home.stateVersion = "25.05";
      }
    ];
  };
in
assert pkgs.lib.hasSuffix " /nix/var/nix/profiles/smind-home/runtimeuser/generation /run/smind-home-manager/runtimeuser"
  alias.config.systemd.services.home-manager-runtimeuser.serviceConfig.ExecStart;
assert alias.config.systemd.services.home-manager-runtimeuser.serviceConfig.User == "runtimeuser";
assert !(pkgs.lib.hasInfix "/bin/home-manager-profile system"
  alias.config.system.activationScripts.smind-home-manager.text);
{
  old = activation "old";
  new = activation "new";
  failing = activation "failing";
}
