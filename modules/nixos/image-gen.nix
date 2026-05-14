{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.image-gen;

  defaultSdcppByBackend = {
    cuda = pkgs.stable-diffusion-cpp-cuda;
    rocm = pkgs.stable-diffusion-cpp-rocm;
    vulkan = pkgs.stable-diffusion-cpp-vulkan;
    cpu = pkgs.stable-diffusion-cpp;
  };

  # GPU backends need access to /dev/dri (and /dev/kfd for ROCm) and the
  # `render` / `video` groups. CUDA exposes /dev/nvidia* directly without
  # group membership.
  gpuGroupsByBackend = {
    cuda = [ ];
    rocm = [ "render" "video" ];
    vulkan = [ "render" "video" ];
    cpu = [ ];
  };
in
{
  options.smind.services.image-gen = {
    enable = lib.mkEnableOption "sd.cpp-webui (Gradio frontend for stable-diffusion.cpp)";

    backend = lib.mkOption {
      type = lib.types.enum [ "cuda" "rocm" "vulkan" "cpu" ];
      example = "rocm";
      description = ''
        Which stable-diffusion.cpp build to expose on the service's PATH.
        Picks the matching nixpkgs variant for `sdcppPackage` unless
        overridden.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sdcpp-webui;
      defaultText = "pkgs.sdcpp-webui";
      description = "The sd.cpp-webui package providing bin/sdcpp-webui.";
    };

    sdcppPackage = lib.mkOption {
      type = lib.types.package;
      default = defaultSdcppByBackend.${cfg.backend};
      defaultText = "pkgs.stable-diffusion-cpp-<backend>";
      description = ''
        Package providing `bin/sd-cli` and `bin/sd-server`. Defaults to
        the nixpkgs variant matching `backend`.
      '';
    };

    listen = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Pass `--listen` so Gradio binds to 0.0.0.0 (home-LAN trust
        model — see feedback memory `feedback_home_lan_trust`).
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 7860;
      description = ''
        TCP port for the Gradio HTTP server. Exposed via
        GRADIO_SERVER_PORT; the upstream script does not pass
        `server_port` to `launch()`, so the env var wins.
      '';
    };

    serverMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Pass `--server` to use the persistent `sd-server` backend
        instead of forking `sd-cli` per request. Faster repeat
        generation; requires the `sd-server` binary from sdcppPackage.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--darkmode" "--allow-insecure-dir" ];
      description = "Extra CLI flags appended to the sdcpp-webui invocation.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the TCP port in the firewall.";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { HSA_OVERRIDE_GFX_VERSION = "11.0.0"; };
      description = "Extra environment variables for the systemd unit.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Expose sd-cli / sd-server on the system PATH so interactive shells
    # (`machinectl shell …`, ssh) can invoke them directly for diagnosis.
    # The service unit's PATH is set independently below.
    environment.systemPackages = [ cfg.sdcppPackage ];

    systemd.services.sdcpp-webui = {
      description = "sd.cpp-webui (Gradio frontend for stable-diffusion.cpp, ${cfg.backend} backend)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # Put sd-cli / sd-server on PATH; the upstream script invokes them
      # by bare name via subprocess.
      path = [ cfg.sdcppPackage ];

      environment = {
        GRADIO_SERVER_PORT = toString cfg.port;
        # The upstream writes config to ./user_data/config.json relative
        # to CWD; StateDirectory below makes CWD writable.
      } // cfg.extraEnvironment;

      serviceConfig = {
        # Upstream reads `config.get('<type>_dir')` at import time and
        # crashes on None when the model subdirectories don't exist.
        # Seed the full tree on every start; `mkdir -p` is idempotent.
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p " + lib.escapeShellArgs [
          "models/checkpoints"
          "models/unet"
          "models/vae"
          "models/text_encoders"
          "models/embeddings"
          "models/loras"
          "models/taesd"
          "models/photomaker"
          "models/upscale_models"
          "models/controlnet"
          "outputs/txt2img"
          "outputs/img2img"
          "outputs/imgedit"
          "outputs/any2video"
          "outputs/upscale"
          "user_data"
        ];

        ExecStart = lib.escapeShellArgs (
          [ (lib.getExe cfg.package) ]
          ++ lib.optional cfg.listen "--listen"
          ++ lib.optional cfg.serverMode "--server"
          ++ cfg.extraArgs
        );

        DynamicUser = true;
        SupplementaryGroups = gpuGroupsByBackend.${cfg.backend};
        PrivateDevices = false;

        # CWD must be writable: upstream creates ./models/, ./outputs/,
        # ./user_data/ on first launch.
        StateDirectory = "sdcpp-webui";
        WorkingDirectory = "/var/lib/sdcpp-webui";

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false;
        SystemCallArchitectures = "native";

        Restart = "on-failure";
        RestartSec = "10s";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
