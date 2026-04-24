{ config
, lib
, cfg-meta
, outerConfig
, ...
}:

let
  rootlessPodmanEnabled =
    cfg-meta.isLinux && (outerConfig.smind.containers.docker.enable or false) 
      && (outerConfig.smind.containers.docker.rootless.enable or false);
  llmSocketUriValue = outerConfig.smind.containers.docker.rootless.llmSocketUri or null;
  # Must match the NixOS-level wiring so we fail fast if the invariant breaks.
  llmSocketUri =
    if !rootlessPodmanEnabled then
      null
    else if llmSocketUriValue == null then
      throw "smind.containers.docker.rootless.llmSocketUri must be set when rootless Podman is enabled"
    else
      llmSocketUriValue;
in
{
  options = {
    smind.hm.containers.docker.enable = lib.mkOption {
      type = lib.types.bool;
      default = rootlessPodmanEnabled;
      description = ''
        Wire this user's interactive shells to the host's restricted-user
        rootless Podman socket by exporting DOCKER_HOST / CONTAINER_HOST.
        Only applies when the NixOS host has rootless Podman enabled.

        Scoped to shell init (home.sessionVariables) on purpose: exporting
        these via NixOS's environment.sessionVariables would leak them into
        every systemd user manager's PAM environment, including podsvc-llm's,
        which causes its own `podman system service` to flip to remote-client
        mode and crash on start.
      '';
    };
  };

  config = lib.mkIf (rootlessPodmanEnabled && config.smind.hm.containers.docker.enable) {
    home.sessionVariables = {
      DOCKER_HOST = llmSocketUri;
      CONTAINER_HOST = llmSocketUri;
    };
  };
}
