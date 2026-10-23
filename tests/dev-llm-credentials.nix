{ flake }:
let
  lib = flake.inputs.nixpkgs.lib;
  helpers = import ../lib/age-user-secret.nix;
  evaluate = { secrets ? { }, system ? "x86_64-linux", llmEnable ? true, githubEnable ? true,
    exportAgentToken ? true, shellAccount ? "shell-fixture", searchEnable ? true,
    agentAccount ? "agent-fixture", policy ? null }:
    (flake.inputs.home-manager.lib.homeManagerConfiguration {
      pkgs = import flake.inputs.nixpkgs { inherit system; };
      extraSpecialArgs = helpers;
      modules = [
        ../modules/hm/globals.nix
        ../modules/hm/nix-access-tokens.nix
        ../modules/hm/dev-llm-credentials.nix
        flake.inputs.ponygirls.homeManagerModules.dev-llm
        {
          home = {
            username = "engineer";
            homeDirectory = "/build/home";
            stateVersion = "26.05";
          };
          smind.hm.globals.age.secrets = secrets;
          smind.hm.dev.llm = {
            enable = llmEnable;
            searchCredentials.enable = searchEnable;
            github = {
              enable = githubEnable;
              inherit exportAgentToken shellAccount;
            } // lib.optionalAttrs (agentAccount != null) { inherit agentAccount; }
              // lib.optionalAttrs (policy != null) { agentPolicy = policy; };
          };
        }
      ];
    }).config;
  # Fixture paths only: no real credentials or files are read during evaluation.
  hostSecrets = {
    github-token-agent-fixture.path = "/fixture/host-agent";
    github-token-shell-fixture.path = "/fixture/host-shell";
    exa.path = "/fixture/host-exa";
    brave.path = "/fixture/brave";
    firecrawl.path = "/fixture/firecrawl";
    tavily.path = "/fixture/tavily";
    serper.path = "/fixture/serper";
    sofya.path = "/fixture/sofya";
    langsearch.path = "/fixture/langsearch";
  };
  scopedSecrets = hostSecrets // {
    "engineer/github-token-agent-fixture".path = "/fixture/user-agent";
    "engineer/exa".path = "/fixture/user-exa";
    "other/github-token-shell-fixture".path = "/fixture/other-shell";
  };
  full = evaluate { secrets = scopedSecrets; };
  darwin = evaluate { system = "aarch64-darwin"; secrets = scopedSecrets; };
  fallback = evaluate { secrets = hostSecrets; };
  scopedShell = evaluate { secrets = scopedSecrets // { "engineer/github-token-shell-fixture".path = "/fixture/user-shell"; }; };
  empty = evaluate { };
  shellOnly = evaluate { secrets.github-token-shell-fixture = hostSecrets.github-token-shell-fixture; };
  agentOnly = evaluate { secrets.github-token-agent-fixture = hostSecrets.github-token-agent-fixture; };
  noExport = evaluate { secrets = hostSecrets; exportAgentToken = false; searchEnable = false; shellAccount = null; };
  noGithub = evaluate { secrets = hostSecrets; githubEnable = false; agentAccount = null; };
  noLlm = evaluate { secrets = hostSecrets; llmEnable = false; };
  policy = evaluate { secrets = hostSecrets; policy = "Fixture policy: ask before publishing."; };
  disabled = evaluate { githubEnable = false; llmEnable = false; agentAccount = null; };
  vars = config: config.smind.hm.dev.llm.yolo.secretSessionVariables;
  tokens = config: config.smind.hm.dev.llm.yolo.forgeTokens;
  nixToken = config: config.smind.hm.nix.githubAccessTokenFile;
  shellConfigured = config: config.programs.git.settings.credential."https://github.com".useHttpPath or false;
in
# BG @specified: evaluate public credentials, real user-secret helpers, Home
# Manager and the real forge-token consumer together, using only fixture paths.
assert lib.assertMsg (nixToken full == "/fixture/user-agent" && (vars full).GH_TOKEN == "/fixture/user-agent") "User-scoped agent credentials must win for Nix and the sandbox";
assert lib.assertMsg (nixToken darwin == nixToken full && vars darwin == vars full && shellConfigured darwin && lib.hasInfix "/fixture/host-shell" darwin.programs.zsh.initContent) "Credential selection must work identically on Darwin";
assert lib.assertMsg (nixToken fallback == "/fixture/host-agent" && (vars fallback).GH_TOKEN == "/fixture/host-agent") "Host credentials must remain the fallback";
assert lib.assertMsg (vars full == {
  GH_TOKEN = "/fixture/user-agent";
  EXA_API_KEY = "/fixture/user-exa";
  BRAVE_SEARCH_API_KEY = "/fixture/brave";
  FIRECRAWL_API_KEY = "/fixture/firecrawl";
  TAVILY_API_KEY = "/fixture/tavily";
  SERPER_API_KEY = "/fixture/serper";
  SOFYA_API_KEY = "/fixture/sofya";
  LANGSEARCH_API_KEY = "/fixture/langsearch";
}) "Search providers must map independently to their selected secret paths";
assert lib.assertMsg (shellConfigured full && lib.hasInfix "/fixture/host-shell" full.programs.zsh.initContent && !(lib.hasInfix "/fixture/other-shell" full.programs.zsh.initContent)) "Shell credentials must use the current user's fallback, not another user's token";
assert lib.assertMsg (lib.hasInfix "/fixture/user-shell" scopedShell.programs.zsh.initContent && !(lib.hasInfix "/fixture/host-shell" scopedShell.programs.zsh.initContent)) "User-scoped shell credentials must override host credentials";
assert lib.assertMsg (lib.hasInfix "SMIND_SANDBOXED" full.programs.zsh.initContent && lib.hasInfix "unset GH_TOKEN" full.programs.zsh.initContent) "Host-shell exports must retain sandbox and unreadable-file guards";
assert lib.assertMsg (nixToken empty == null && tokens empty == [ ] && vars empty == { } && !shellConfigured empty) "Absent secrets must deactivate each consumer without errors";
assert lib.assertMsg (nixToken shellOnly == null && tokens shellOnly == [ ] && shellConfigured shellOnly && vars shellOnly == { }) "Shell credentials must not depend on an agent secret";
assert lib.assertMsg (nixToken agentOnly == "/fixture/host-agent" && (vars agentOnly).GH_TOKEN == "/fixture/host-agent" && !shellConfigured agentOnly && builtins.attrNames (vars agentOnly) == [ "GH_TOKEN" ]) "Agent credentials must survive absent shell and search secrets";
assert lib.assertMsg (nixToken noExport == "/fixture/host-agent" && tokens noExport == [ ] && vars noExport == { } && !shellConfigured noExport) "Agent export, search export and shell export must be independently disableable";
assert lib.assertMsg (nixToken noGithub == null && tokens noGithub == [ ] && !(vars noGithub ? GH_TOKEN) && (vars noGithub).EXA_API_KEY == "/fixture/host-exa" && !shellConfigured noGithub) "Disabled GitHub must not require an account or disable search";
assert lib.assertMsg (nixToken noLlm == "/fixture/host-agent" && (vars noLlm) == { GH_TOKEN = "/fixture/host-agent"; } && shellConfigured noLlm) "GitHub wiring must remain independent of the harness enable flag";
assert lib.assertMsg ((builtins.head (tokens full)).policy == "" && (builtins.head (tokens policy)).policy == "Fixture policy: ask before publishing.") "Public credentials must grant no additional policy authorization unless explicitly configured";
assert lib.assertMsg (nixToken disabled == null && tokens disabled == [ ] && vars disabled == { }) "Disabled consumers must not force the required agent account";
assert lib.assertMsg (!(builtins.tryEval (nixToken (evaluate { agentAccount = null; }))).success) "Enabled GitHub credentials must require an explicit agent account";
{
  userScopedPrecedence = true;
  hostFallback = true;
  perSecretFiltering = true;
  independentEnables = true;
  explicitPolicy = true;
  darwin = true;
}
