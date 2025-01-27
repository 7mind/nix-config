{ pkgs, lib, config, cfg-meta, ... }:

{
  options = {
    smind.host.email.to = lib.mkOption {
      type = lib.types.str;
      description = "";
    };

    smind.host.email.sender = lib.mkOption {
      type = lib.types.str;
      description = "";
    };
  };

  config = {
    programs.msmtp = {
      #enable = true;
      setSendmail = true;
      defaults = {
        aliases = "/etc/aliases";
        port = 587;
        tls_trust_file = "/etc/ssl/certs/ca-certificates.crt";
        tls = "on";
        auth = "login";
        tls_starttls = "on";
      };
      extraConfig = ''
        set_from_header on
        syslog LOG_MAIL
        #logfile /tmp/msmtp.log
      '';
      accounts = {
        default = {
          host = "smtp.sendgrid.net";
          passwordeval = "cat ${config.age.secrets.msmtp-password.path}";
          user = "apikey";
          from = "%U.${config.smind.host.email.sender}";
        };
      };
    };

    environment.etc.aliases.text = "default: ${config.smind.host.email.to}";

    age.secrets.msmtp-password = {
      rekeyFile = "${cfg-meta.paths.secrets}/generic/msmtp-password.age";
      mode = "444";
    };

  };
}
