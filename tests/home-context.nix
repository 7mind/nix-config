{ flake }:
let
  lib = flake.inputs.nixpkgs.lib;
  make = flake.globals.make-home { inputs = flake.inputs; self = flake; };
  ubuntu = import ../home/pavel-ubuntu.nix;
  standalone = make ubuntu;
  relocated = make (ubuntu // {
    username = "alex";
    host = {
      hostname = "other-workstation";
      system = "x86_64-linux";
      homeDirectories.alex = "/srv/homes/alex";
      globals.isDesktop = false;
    };
  });
  vpn = make (ubuntu // {
    host = ubuntu.host // {
      globals = ubuntu.host.globals // { net.namespaces = [ "vpn" ]; };
    };
  });
  root = system: make {
    source = "root";
    username = "root";
    host = {
      hostname = "standalone-root";
      inherit system;
      homeDirectories.root = "/root";
      globals = { };
    };
  };
  failedAssertions = home: builtins.filter (a: !a.assertion) home.value.config.assertions;
  worker = flake.nixosConfigurations.pavel-trx40.config.home-manager.users.llm;
  config = standalone.value.config;
  otherConfig = relocated.value.config;
  nixos = flake.nixosConfigurations.pavel-fw.config;
  profile = "/nix/var/nix/profiles/smind-home/pavel/generation";
  privateContexts =
    if builtins.pathExists ../private/tests/home-context.nix then
      import ../private/tests/home-context.nix { inherit flake; }
    else { exports = [ ]; };
in
assert lib.assertMsg (standalone.name == "pavel@ubuntu-x86_64") "Standalone export must use the supplied hostname and architecture";
assert lib.assertMsg (config.home.username == "pavel" && config.home.homeDirectory == "/home/pavel") "Standalone identity must come from its context";
assert lib.assertMsg (config.smind.hm.globals.isDesktop && !config.smind.hm.globals.llama-swap.enable) "Standalone capabilities must come from its declaration";
assert lib.assertMsg (vpn.value.config.smind.hm.electron-wrappers.slack.netns == "vpn") "Declared VPN namespaces must remain enabled";
assert lib.assertMsg (config.smind.hm.electron-wrappers.slack.netns == null) "Standalone Slack must not require an unavailable VPN namespace";
assert lib.assertMsg (builtins.filter (a: !a.assertion) worker.assertions == [ ]) "Role-created homes must receive their host context";
assert lib.assertMsg (failedAssertions standalone == [ ]) "Standalone configuration must pass assertions";
assert lib.assertMsg (otherConfig.home.username == "alex" && otherConfig.home.homeDirectory == "/srv/homes/alex") "The same source must support a different user and home directory";
assert lib.assertMsg (!otherConfig.smind.hm.globals.isDesktop && failedAssertions relocated == [ ]) "The same source must support different capabilities";
assert lib.assertMsg (relocated.name == "alex@other-workstation-x86_64") "Source names must not determine instance names";
assert lib.assertMsg ((root "x86_64-linux").value.pkgs.stdenv.hostPlatform.system == "x86_64-linux") "Root must support x86_64 context";
assert lib.assertMsg ((root "aarch64-linux").value.pkgs.stdenv.hostPlatform.system == "aarch64-linux") "Root must support aarch64 context";
assert lib.assertMsg (builtins.attrNames flake.homeConfigurations == builtins.sort builtins.lessThan ([ standalone.name ] ++ privateContexts.exports)) "Only explicitly declared standalone instances may be exported";
assert lib.assertMsg nixos.home-manager.useUserPackages "NixOS must keep Home Manager packages visible through the system profile";
assert lib.assertMsg (nixos.environment.etc."profiles/per-user/pavel".source == "${profile}/home-path") "NixOS packages must follow the selected Home Manager generation";
assert lib.assertMsg (nixos.environment.etc."smind/home-manager/pavel".text == "${profile}\n") "HM-only switches must discover the persistent profile from the installed system";
assert lib.assertMsg (lib.hasSuffix " ${profile} /run/smind-home-manager/pavel" nixos.systemd.services.home-manager-pavel.serviceConfig.ExecStart) "Boot activation must follow the selected profile";
assert lib.assertMsg (builtins.elem "multi-user.target" nixos.systemd.services.home-manager-pavel.wantedBy) "The selected Home Manager generation must activate at boot";
assert lib.assertMsg (standalone.value.pkgs.far2l-noui.drvPath == flake.nixosConfigurations.pavel-fw.pkgs.far2l-noui.drvPath) "Standalone Home Manager must apply the shared package overlays";
{
  standalone = true;
  relocated = true;
  architectures = true;
  explicitExports = true;
  roleContext = true;
}
