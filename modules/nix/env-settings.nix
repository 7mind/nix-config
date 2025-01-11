{ config, lib, ... }:

{
  options = {
    smind.environment.sane-defaults.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "";
    };
  };

  config = lib.mkIf config.smind.environment.sane-defaults.enable {
    assertions = [ ];

    boot = {
      tmp.useTmpfs = true;
      tmp.cleanOnBoot = true;
    };

    security.pam = {
      loginLimits = [
        {
          domain = "*";
          item = "nofile";
          type = "hard";
          value = "524288";
        }
        {
          domain = "*";
          item = "nofile";
          type = "soft";
          value = "524288";
        }
      ];
    };

    environment = {
      enableDebugInfo = true;
    };

  };
}
