{ config, lib, ... }:

let
  cfg = config.smind.containers.docker;
  llmServiceUser = "podsvc-llm";
  llmServiceId = 77778;
  llmSocketDir = "/run/podman-llm";
  llmSocketPath = "${llmSocketDir}/podman.sock";
  llmSocketUri = "unix://${llmSocketPath}";
  homeManagerUsers =
    if builtins.hasAttr "home-manager" config then config.home-manager.users else { };
  llmSocketUsers = builtins.filter (
    name:
    name != "root" && lib.attrByPath [ name "smind" "hm" "dev" "llm" "enable" ] false homeManagerUsers
  ) (builtins.attrNames homeManagerUsers);
  missingLlmSocketUsers = builtins.filter (
    name: !(builtins.hasAttr name config.users.users)
  ) llmSocketUsers;
in
{
  options.smind.containers.docker = {
    enable = lib.mkEnableOption "Podman with Docker compatibility";
    rootless.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable rootless Podman and mask the rootful system socket";
    };
    rootless.llmServiceUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      description = "Dedicated rootless Podman service user for yolo-mode LLM wrappers";
    };
    rootless.llmSocketPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      description = "Dedicated rootless Podman socket path for yolo-mode LLM wrappers";
    };
    rootless.llmSocketUri = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      description = "Dedicated rootless Podman socket URI for yolo-mode LLM wrappers";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        virtualisation.podman = {
          enable = true;
          dockerCompat = true;
          dockerSocket.enable = !cfg.rootless.enable;
          # extraPackages = with pkgs; [ aardvark-dns netavark zfs ];
          # defaultNetwork.settings.dns_enabled = true;
        };
      }
      (lib.mkIf cfg.rootless.enable {
        # Parent directory for the LLM podman socket. 0750 lets members of the
        # podsvc-llm group traverse it; the socket itself is created 0660 below.
        # Lives outside /run/user/$UID because that dir is 0700 and unreachable
        # to other users regardless of group membership.
        systemd.tmpfiles.rules = [
          "d ${llmSocketDir} 0750 ${llmServiceUser} ${llmServiceUser} -"
        ];

        # Dedicated user units (separate name from podman.socket so this only
        # affects podsvc-llm — other users still get default on-demand behavior).
        # No wantedBy: the unit is available to every user manager but only
        # started for podsvc-llm by the trigger service below.
        systemd.user.sockets.podman-llm = {
          unitConfig.Description = "Podman API Socket (LLM service user)";
          socketConfig = {
            ListenStream = llmSocketPath;
            SocketMode = "0660";
          };
        };

        systemd.user.services.podman-llm = {
          unitConfig = {
            Description = "Podman API Service (LLM service user)";
            Requires = "podman-llm.socket";
            After = "podman-llm.socket";
          };
          serviceConfig = {
            Type = "exec";
            ExecStart = "${config.virtualisation.podman.package}/bin/podman system service --time=0";
            KillMode = "process";
            Delegate = true;
          };
        };

        # Start the socket inside the podsvc-llm user manager once it's up.
        # reset-failed first so that a rebuild can recover from a prior
        # service-start-limit-hit without requiring a reboot.
        systemd.services."podman-llm-socket" = {
          description = "Start podman-llm.socket inside ${llmServiceUser} user manager";
          after = [ "user@${toString llmServiceId}.service" ];
          requires = [ "user@${toString llmServiceId}.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = [
              "-${config.systemd.package}/bin/systemctl --user --machine=${llmServiceUser}@ reset-failed podman-llm.socket podman-llm.service"
              "${config.systemd.package}/bin/systemctl --user --machine=${llmServiceUser}@ start podman-llm.socket"
            ];
          };
        };

        assertions = [
          {
            assertion = missingLlmSocketUsers == [ ];
            message = "Every Home Manager user with smind.hm.dev.llm.enable must also exist under users.users: ${lib.concatStringsSep ", " missingLlmSocketUsers}";
          }
        ];

        # DOCKER_HOST / CONTAINER_HOST are intentionally NOT set system-wide
        # here — doing so via environment.sessionVariables leaks them into
        # every systemd user manager's PAM environment, including podsvc-llm's,
        # which breaks its own `podman system service` (flips to remote-client
        # mode and crashes on start). Per-user wiring lives in
        # modules/hm/docker.nix (shell-level home.sessionVariables only).

        smind.containers.docker.rootless.llmServiceUser = llmServiceUser;
        smind.containers.docker.rootless.llmSocketPath = llmSocketPath;
        smind.containers.docker.rootless.llmSocketUri = llmSocketUri;

        users.groups.${llmServiceUser} = {
          gid = llmServiceId;
        };
        users.users = {
          ${llmServiceUser} = {
            uid = llmServiceId;
            group = llmServiceUser;
            isNormalUser = true;
            createHome = true;
            home = "/home/${llmServiceUser}";
            linger = true;
            autoSubUidGidRange = true;
          };
        }
        // builtins.listToAttrs (
          map (name: {
            name = name;
            value.extraGroups = [ llmServiceUser ];
          }) llmSocketUsers
        );

        systemd.services.podman.enable = lib.mkForce false;
        systemd.sockets.podman.enable = lib.mkForce false;
      })
    ]
  );
}
