{ config, lib, ... }:

{
  options = {
    smind.xxx = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.xxx {
    assertions = [ ];
  };
}
