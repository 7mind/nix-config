{ lib, config, ... }: {
  options = {
    smind.hw.cpu.isAmd = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
    smind.hw.cpu.isIntel = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };

  };

  config = lib.mkIf config.smind.nix.customize {
    assertions = [
      ({
        assertion = config.smind.hw.cpu.isAmd != config.smind.hw.cpu.isIntel;
        message = "Just one CPU type flag must be set";
      })
    ];
  };

}
