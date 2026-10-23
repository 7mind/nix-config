{ config, lib, ageUserSecret, ageUserSecretExists, ... }:
let
  cfg = config.smind.hm.dev.llm;
  githubCfg = cfg.github;
  userSecret = ageUserSecret {
    secrets = config.smind.hm.globals.age.secrets;
    user = config.home.username;
  };
  # Each consumer deactivates independently when its secret is absent or
  # filtered out by the host. User-scoped secrets take precedence.
  hasUserSecret = ageUserSecretExists {
    secrets = config.smind.hm.globals.age.secrets;
    user = config.home.username;
  };
  searchSecrets = {
    EXA_API_KEY = "exa";
    BRAVE_SEARCH_API_KEY = "brave";
    FIRECRAWL_API_KEY = "firecrawl";
    TAVILY_API_KEY = "tavily";
    SERPER_API_KEY = "serper";
    SOFYA_API_KEY = "sofya";
    LANGSEARCH_API_KEY = "langsearch";
  };
  agentTokenSecret = "github-token-${githubCfg.agentAccount}";
  shellTokenSecret = if githubCfg.shellAccount == null then null else "github-token-${githubCfg.shellAccount}";
  agentTokenPath = (userSecret agentTokenSecret).path;
  shellTokenPath = (userSecret shellTokenSecret).path;
in
{
  options.smind.hm.dev.llm = {
    searchCredentials.enable = lib.mkEnableOption "user-specific search API credentials for the agent harnesses";
    github = {
      enable = lib.mkEnableOption "GitHub account credentials";
      agentAccount = lib.mkOption {
        type = lib.types.str;
        description = "GitHub account whose github-token-<account> secret authenticates Nix API requests and optional agent sessions.";
      };
      shellAccount = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "GitHub account whose token is exported in host shells; null disables the export.";
      };
      exportAgentToken = lib.mkEnableOption "exporting the agent account token as GH_TOKEN in Yolo sessions";
      agentPolicy = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Operator-supplied policy for the agent GitHub token. No additional authorization is granted by default.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && cfg.searchCredentials.enable) {
      smind.hm.dev.llm.yolo.secretSessionVariables =
        lib.mapAttrs (_: name: (userSecret name).path) (lib.filterAttrs (_: name: hasUserSecret name) searchSecrets);
    })
    # GitHub wiring intentionally does not depend on cfg.enable: Nix and host
    # shells can use credentials even when the agent harnesses are disabled.
    (lib.mkIf (githubCfg.enable && hasUserSecret agentTokenSecret) {
      smind.hm.nix.githubAccessTokenFile = agentTokenPath;
    })
    (lib.mkIf (githubCfg.enable && githubCfg.exportAgentToken && hasUserSecret agentTokenSecret) {
      smind.hm.dev.llm.yolo.forgeTokens = [
        {
          account = githubCfg.agentAccount;
          forge = "github";
          tokenFile = agentTokenPath;
          default = true;
          operations = [ "read" "push" "issues" "pull-requests" "comments" "discussions" "releases" "packages" "workflows" "wiki" "administration" ];
          policy = githubCfg.agentPolicy;
        }
      ];
    })
    (lib.mkIf (githubCfg.enable && shellTokenSecret != null && hasUserSecret shellTokenSecret) {
      programs.git.settings.credential."https://github.com".useHttpPath = true;
      programs.zsh.initContent = ''
        if [[ -z ''${SMIND_SANDBOXED:-} ]]; then
          if [[ -r ${lib.escapeShellArg shellTokenPath} && -s ${lib.escapeShellArg shellTokenPath} ]]; then
            export GH_TOKEN="$(< ${lib.escapeShellArg shellTokenPath})"
          else
            unset GH_TOKEN
            print -u2 'GitHub token secret is missing or unreadable: ${shellTokenPath}'
          fi
        fi
      '';
    })
  ];
}
