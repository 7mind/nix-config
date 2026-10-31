{ flake }:
let
  lib = flake.inputs.nixpkgs.lib;
  build = flake.globals.make-home-from-modules { inputs = flake.inputs; self = flake; };
  home = build {
    modules = [ ({ smind-hm, ... }: {
      imports = smind-hm.imports;
      smind.hm.roles.server = true;
      smind.hm.firefox.enable = true;
    }) ];
    username = "alex";
    host = {
      hostname = "firefox-test";
      system = "x86_64-linux";
      homeDirectories.alex = "/srv/homes/alex";
      globals.isDesktop = false;
    };
  };
  config = home.value.config;
in
# BG @specified: shared Firefox defaults must apply without the desktop role.
assert lib.assertMsg (!config.smind.hm.firefox.no-tabbar) "Firefox must preserve the opt-in tab-hiding setting";
assert lib.assertMsg (config.programs.firefox.profiles.main.settings."browser.nova.enabled" == false) "Firefox must disable Nova";
{
  novaDisabled = true;
  tabbarOptIn = true;
}
