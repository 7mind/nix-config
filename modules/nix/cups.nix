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

    hardware.printers = {
      ensurePrinters = [
        {
          name = "Brother";
          location = "Home";
          deviceUri = "ipp://printer.local:631/ipp/print";
          model = "everywhere";
          ppdOptions = {
            "Duplex" = "DuplexNoTumble";
          };
        }
      ];
      ensureDefaultPrinter = "Brother";
    };

  };

}
