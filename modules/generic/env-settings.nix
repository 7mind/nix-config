{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.with-private = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Private secrets are available for this configuration";
    };

    smind.age.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.with-private;
      description = "Enable age secrets support. Defaults to with-private, but can be disabled per-host.";
    };
  };

  config = { };
}
