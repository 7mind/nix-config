{ flake, privateRoot ? null }:
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
  # Owner-secret consumers must degrade per-secret when a host filters the
  # standard set with smind.age.owner-secrets: pavel-trx40 loads only
  # "github-*", pavel-am5 loads the full set. The consumers live in private HM
  # modules, so these checks only run when the downstream root is present.
  hasPrivate = privateRoot != null && builtins.pathExists (privateRoot + "/home/pavel-trx40.nix");
  hasTrx40 = builtins.hasAttr "pavel-trx40" flake.nixosConfigurations;
  trx40Pavel = flake.nixosConfigurations.pavel-trx40.config.home-manager.users.pavel;
  am5Pavel = flake.nixosConfigurations.pavel-am5.config.home-manager.users.pavel;
  testbenchPavel = flake.nixosConfigurations.testbench.config.home-manager.users.pavel;
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
  disabledAge = home:
    let
      config = home.value.config;
    in
    assert lib.assertMsg (config ? age && config.age ? rekey) "Standalone Home Manager must expose agenix and agenix-rekey options";
    assert lib.assertMsg (!config.age.enable && config.age.secrets == { }) "Standalone agenix must remain disabled with no secrets";
    assert lib.assertMsg (failedAssertions home == [ ]) "Disabled standalone agenix-rekey must pass assertions without keys";
    assert lib.assertMsg (!home.value.pkgs.stdenv.hostPlatform.isLinux || !(config.systemd.user.services ? agenix)) "Disabled standalone agenix must not install a user service";
    assert lib.assertMsg (!home.value.pkgs.stdenv.hostPlatform.isDarwin || !(config.launchd.agents ? activate-agenix)) "Disabled standalone agenix must not install a launch agent";
    true;
  worker = flake.nixosConfigurations.testbench.config.home-manager.users.llm;
  config = standalone.value.config;
  otherConfig = relocated.value.config;
  nixos = flake.nixosConfigurations.testbench;
  privateContexts = flake.globals.importPrivate "tests/home-context.nix" (_: { exports = [ ]; }) { inherit flake; };
in
assert lib.assertMsg (!hasPrivate || trx40Pavel.smind.hm.nix.githubAccessTokenFile == "/run/agenix/github-token-autopeasant") "pavel-trx40: the agent GitHub token must survive owner secret filtering";
assert lib.assertMsg (!hasPrivate || trx40Pavel.smind.hm.dev.llm.yolo.secretSessionVariables.GH_TOKEN == "/run/agenix/github-token-autopeasant") "pavel-trx40: the agent GH_TOKEN must survive owner secret filtering";
assert lib.assertMsg (!hasPrivate || trx40Pavel.programs.git.signing.key == null) "pavel-trx40: git SSH signing must deactivate when id_ed25519.pub is filtered out";
assert lib.assertMsg (!hasPrivate || am5Pavel.smind.hm.nix.githubAccessTokenFile == "/run/agenix/github-token-autopeasant") "pavel-am5: GitHub wiring must be unchanged for the unfiltered set";
assert lib.assertMsg (!hasPrivate || am5Pavel.programs.git.signing.key == "/run/agenix/id_ed25519.pub") "pavel-am5: git SSH signing must stay wired for the unfiltered set";
assert lib.assertMsg (testbenchPavel.smind.hm.dev.git.enable && testbenchPavel.programs.git.enable) "testbench: dev.git must be enabled via roles.desktop";
assert lib.assertMsg (builtins.any (p: lib.getName p == "tig") testbenchPavel.home.packages) "testbench: tig must be in home.packages";
assert lib.assertMsg (!hasTrx40 || !trx40Pavel.smind.hm.dev.git.rewriteGithubToSsh) "pavel-trx40: GitHub must stay on HTTPS (the host SSH key is not registered on GitHub)";
assert lib.assertMsg (!hasTrx40 || lib.hasInfix "gh auth git-credential" (trx40Pavel.programs.git.settings.credential."https://github.com".helper or "")) "pavel-trx40: GitHub HTTPS credentials must come from gh (a manual ~/.gitconfig would shadow the HM git config)";
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
assert builtins.deepSeq (map disabledAge [ standalone relocated (root "aarch64-darwin") ]) true;
assert lib.assertMsg (builtins.attrNames flake.homeConfigurations == builtins.sort builtins.lessThan ([ standalone.name ] ++ privateContexts.exports)) "Only explicitly declared standalone instances may be exported";
assert lib.assertMsg (nixos.config.smind.home-manager.enable && nixos.config.home-manager.useUserPackages) "The host must enable persistent Home Manager with external package installation";
assert lib.assertMsg (standalone.value.pkgs.far2l-noui.drvPath == nixos.pkgs.far2l-noui.drvPath) "Standalone Home Manager must apply the shared package overlays";
{
  standalone = true;
  relocated = true;
  architectures = true;
  explicitExports = true;
  standaloneAgeDisabled = true;
  roleContext = true;
  ownerSecrets = true;
  ownerSecretsFiltered = true;
}
