{ lib, config, ... }:
let
  sumList = xs: builtins.foldl' (acc: x: acc + x) 0 xs;
in
{
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

    smind.hw.cpu.isIA64 = lib.mkOption {
      type = lib.types.bool;
      default = config.smind.hw.cpu.isAmd || config.smind.hw.cpu.isIntel;
      description = "";
    };

    smind.hw.cpu.isArm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.nix.customize {
    assertions = [
      ({
        assertion = (sumList (map (b: if b then 1 else 0) [ config.smind.hw.cpu.isIA64 config.smind.hw.cpu.isArm ])) == 1;
        message = "Exactly one CPU arch flag must be set";
      })

      ({
        assertion = config.smind.hw.cpu.isIA64 && (sumList (map (b: if b then 1 else 0) [ config.smind.hw.cpu.isIntel config.smind.hw.cpu.isAmd ])) == 1 || config.smind.hw.cpu.isArm;
        message = "Exactly one IA64 CPU type flag must be set";
      })
    ];
  };

}
