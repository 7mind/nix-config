{ config
, lib
, pkgs
, ...
}:
let
  inherit (lib) types;

  cfg = config.services.tabby-extended;
  format = pkgs.formats.toml { };
  tabbyPackage = cfg.package.override {
    inherit (cfg) acceleration;
  };
in
{
  options.services.tabby-extended = {
    enable = lib.mkEnableOption "Self-hosted AI coding assistant using large language models";
    package = lib.mkPackageOption pkgs "tabby" { };

    port = lib.mkOption {
      type = types.port;
      default = 11029;
    };

    chatModel = lib.mkOption {
      type = types.str;
      default = "TabbyML/Qwen2-1.5B-Instruct";
    };

    model = lib.mkOption {
      type = types.str;
      default = "TabbyML/StarCoder-1B";
    };

    settings = lib.mkOption {
      inherit (format) type;
      default = {
        model.completion.local.model_id = cfg.model;
        model.chat.local.model_id = cfg.chatModel;
      };
    };

    acceleration = lib.mkOption {
      type = types.nullOr (
        types.enum [
          "cpu"
          "rocm"
          "cuda"
          "metal"
        ]
      );
      default = null;
      example = "rocm";
      description = ''
        Specifies the device to use for hardware acceleration.

        -   `cpu`: no acceleration just use the CPU
        -  `rocm`: supported by modern AMD GPUs
        -  `cuda`: supported by modern NVIDIA GPUs
        - `metal`: supported on darwin aarch64 machines

        Tabby will try and determine what type of acceleration that is
        already enabled in your configuration when `acceleration = null`.

        - nixpkgs.config.cudaSupport
        - nixpkgs.config.rocmSupport
        - if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64

        IFF multiple acceleration methods are found to be enabled or if you
        haven't set either `cudaSupport or rocmSupport` you will have to
        specify the device type manually here otherwise it will default to
        the first from the list above or to cpu.
      '';
    };

    usageCollection = lib.mkOption {
      type = types.bool;
      default = false;
    };
  };

  config = lib.mkIf cfg.enable {
    environment = {
      etc."tabby/config.toml".source = format.generate "config.toml" cfg.settings;
      systemPackages = [ tabbyPackage ];
    };

    systemd.services.tabby = {
      wantedBy = [ "multi-user.target" ];
      description = "Self-hosted AI coding assistant using large language models";
      after = [ "network.target" ];

      environment.TABBY_ROOT = "%S/tabby";
      environment.TABBY_DISABLE_USAGE_COLLECTION = if !cfg.usageCollection then "1" else "0";
      environment.ZES_ENABLE_SYSMAN = lib.optionalString (cfg.acceleration == "sycl") "1";

      preStart = "cp -f /etc/tabby/config.toml \${TABBY_ROOT}/config.toml";
      unitConfig = {

      };
      serviceConfig = {
        WorkingDirectory = "/var/lib/tabby";
        StateDirectory = [ "tabby" ];
        ConfigurationDirectory = [ "tabby" ];
        DynamicUser = true;
        User = "tabby";
        Group = "tabby";
        ExecStart = "${lib.getExe tabbyPackage} serve --port ${toString cfg.port} --device ${tabbyPackage.featureDevice}";
      };
    };
  };

  meta.maintainers = with lib.maintainers; [ ];
}
