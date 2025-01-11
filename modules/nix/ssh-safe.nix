{ config, lib, ... }:

{
  options = {
    smind.ssh.safe = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.ssh.safe {
  };
}
