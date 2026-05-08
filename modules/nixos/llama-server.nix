{ config, lib, pkgs, ... }:

let
  cfg = config.smind.services.llama-server;
in
{
  options.smind.services.llama-server = {
    enable = lib.mkEnableOption "llama-server (llama.cpp's OpenAI-compatible HTTP server) backed by our SYCL build for the Intel Arc Pro B70";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.llama-cpp-sycl;
      defaultText = "pkgs.llama-cpp-sycl";
      description = "Package providing bin/llama-server. Defaults to our SYCL-patched build.";
    };

    model = lib.mkOption {
      type = lib.types.path;
      example = "/srv/disks-models/Qwen3.6-27B-Q4_K_M.gguf";
      description = ''
        Absolute path to the GGUF model file to serve. The systemd unit
        does not pull or convert models — point this at a file that
        already exists on disk.
      '';
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = ''
        Listen address. Default 0.0.0.0 (home-LAN trust model — see
        memory `feedback_home_lan_trust`); router walls off WAN.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 11435;
      description = ''
        TCP port for the OpenAI-compatible HTTP API. Default 11435 to
        sit alongside ollama (11434) without colliding.
      '';
    };

    nGpuLayers = lib.mkOption {
      type = lib.types.int;
      default = 99;
      description = ''
        Number of layers to offload to the GPU (-ngl). 99 means "all
        layers"; only reduce on memory pressure for very large models.
      '';
    };

    contextSize = lib.mkOption {
      type = lib.types.int;
      default = 8192;
      description = ''
        KV-cache context size (-c). Larger = more memory. The B70 is
        32 GB; for a 27B Q4_K_M model the model+context already
        approaches the cap at 8k context.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--temp" "0" "--threads" "8" ];
      description = ''
        Extra CLI flags appended to the llama-server invocation. See
        `llama-server --help`.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the TCP port in the firewall.";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { ZES_ENABLE_SYSMAN = "1"; };
      description = ''
        Extra environment variables for the systemd unit. The package's
        `wrapProgram` already injects `ONEAPI_DEVICE_SELECTOR=opencl:gpu`
        and `OCL_ICD_VENDORS=…/opengl-driver/etc/OpenCL/vendors`; only
        set entries here that you want to override or add.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.llama-server = {
      description = "llama.cpp HTTP server (OpenAI-compatible) backed by SYCL on Intel Arc";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = cfg.extraEnvironment;

      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/llama-server"
            "--model" (toString cfg.model)
            "--host" cfg.host
            "--port" (toString cfg.port)
            "-ngl" (toString cfg.nGpuLayers)
            "-c" (toString cfg.contextSize)
          ] ++ cfg.extraArgs
        );

        # GPU access — we need /dev/dri (xe driver) plus the user-mode
        # ICD loader. Run as a dedicated dynamic user so we don't need
        # to manage UIDs.
        DynamicUser = true;
        SupplementaryGroups = [ "render" "video" ];
        DeviceAllow = [
          "/dev/dri/renderD128 rw"
          "/dev/dri/card0 rw"
        ];
        PrivateDevices = false;

        # Sandboxing — llama-server only reads the model and writes
        # logs / cache. Lock down everything else.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false;  # SYCL JIT mmaps W+X
        SystemCallArchitectures = "native";

        # Resource hygiene
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStartSec = "10min";  # First boot JIT-compiles all SYCL kernels — slow

        # Persist the SYCL JIT cache between restarts so we don't pay the
        # 5+ minute cold-cache hit on every reboot. StateDirectory under
        # /var/lib/llama-server/cache.
        StateDirectory = "llama-server";
        Environment = [
          "XDG_CACHE_HOME=/var/lib/llama-server/cache"
        ];
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
