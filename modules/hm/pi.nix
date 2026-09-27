# Pi network/retry policy and the Xiaomi MiMo Token Plan (AMS) strict profile.
#
# Pi 0.87.1 has no provider-scoped retry/timeout settings (its RetrySettings
# is flat and global), so the Xiaomi AMS policy is scoped with a
# PI_CODING_AGENT_DIR profile at ~/.pi/agent-xiaomi-ams: its settings.json is
# the shared settings overridden with the strict policy, and every other
# agent-dir entry is a symlink back to the shared ~/.pi/agent state.
#
#   PI_CODING_AGENT_DIR=~/.pi/agent-xiaomi-ams pi
#
# retry.provider.maxRetries stays 0 in both policies: only Pi's agent layer
# retries, never the OpenAI-compatible SDK underneath it.
{ config, lib, pkgs, ... }:
let
  cfg = config.smind.hm.dev.llm;
  agentDir = "${config.home.homeDirectory}/.pi/agent";
  xiaomiProfileRelDir = ".pi/agent-xiaomi-ams";

  generalRetryPolicy = {
    httpIdleTimeoutMs = 120000;
    retry = {
      enabled = true;
      maxRetries = 2;
      baseDelayMs = 1000;
      maxAgentDelayMs = 10000;
      provider = {
        timeoutMs = 120000;
        maxRetries = 0;
        maxRetryDelayMs = 15000;
      };
    };
  };

  xiaomiRetryPolicy = {
    httpIdleTimeoutMs = 60000;
    retry = {
      enabled = true;
      maxRetries = 1;
      baseDelayMs = 1000;
      maxAgentDelayMs = 5000;
      provider = {
        timeoutMs = 60000;
        maxRetries = 0;
        maxRetryDelayMs = 10000;
      };
    };
  };

  # Shared agent-dir entries; settings.json is the profile's only override.
  sharedAgentDirEntries = [
    "AGENTS.md"
    "APPEND_SYSTEM.md"
    "auth.json"
    "cache"
    "exa-usage.json"
    "extensions"
    "mcp-cache.json"
    "mcp-onboarding.json"
    "mcp.json"
    "models-store.json"
    "models.json"
    "npm"
    "prompts"
    "role-tool-profiles.json"
    "sessions"
    "skills"
    "trust.json"
  ];
in
{
  config = lib.mkIf cfg.enable {
    programs.pi.settings = generalRetryPolicy;

    home.file = lib.listToAttrs (
      [
        {
          name = "${xiaomiProfileRelDir}/settings.json";
          value.source = (pkgs.formats.json { }).generate "pi-settings-xiaomi-ams.json" (
            config.programs.pi.settings // xiaomiRetryPolicy
          );
        }
      ]
      ++ map (name: {
        name = "${xiaomiProfileRelDir}/${name}";
        value.source = config.lib.file.mkOutOfStoreSymlink "${agentDir}/${name}";
      }) sharedAgentDirEntries
    );
  };
}
