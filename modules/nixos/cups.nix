{ lib, config, ... }:

{
  options = {
    smind.environment.cups.enable = lib.mkEnableOption "CUPS printing with PDF printer and network discovery";
  };

  config = lib.mkIf config.smind.environment.cups.enable {
    services = {
      printing.enable = true;
      system-config-printer.enable = true;
      printing.cups-pdf = {
        enable = true;
        instances.pdf.settings = {
          Out = "\${HOME}/Downloads/cups-pdf";
        };
      };
      avahi.enable = true;
    };

    programs.system-config-printer.enable = true;


  };

}
