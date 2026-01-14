{ config, lib, ... }:

{
  options = {
    smind.xxx = lib.mkEnableOption "";
  };

  config = lib.mkIf config.smind.xxx {
    assertions = [ ];
  };
}
