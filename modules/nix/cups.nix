{ pkgs, lib, config, ... }: {
  options = {
    smind.environment.cups.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.environment.cups.enable {
    services = {
      printing.enable = true;
    };
  };

}
