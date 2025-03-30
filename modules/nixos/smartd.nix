{ lib, config, ... }:

{
  options = {
    smind.smartd.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };

    smind.smartd.email.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.programs.msmtp.enable;
      description = "";
    };
  };

  config = lib.mkIf config.smind.smartd.enable {


    assertions = [
      ({
        assertion = !config.smind.zfs.email.enable || config.programs.msmtp.enable;
        message = "msmtp must be configured for smartd mailer to work ( set programs.msmtp.enable=true )";
      })
    ];

    services.smartd = {
      enable = true;
      notifications = lib.mkIf config.smind.smartd.email.enable {
        test = false;
        mail.recipient = config.smind.host.email.to;
        mail.sender = "${config.smind.host.email.sender}";
      };

    };
  };
}
