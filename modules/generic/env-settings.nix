{ config, lib, pkgs, cfg-meta, ... }:

{
  options = {
    smind.with-private = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = { };
}
