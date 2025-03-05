{ config, lib, ... }:

{
  options = {
    smind.locale.ie.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "";
    };
  };

  config = lib.mkIf config.smind.locale.ie.enable {
    time.timeZone = "Europe/Dublin";
    i18n.defaultLocale = "en_IE.UTF-8";
  };
}
