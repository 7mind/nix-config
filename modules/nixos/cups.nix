{ pkgs, lib, config, cfg-meta, ... }: {
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


    # https://github.com/NixOS/nixpkgs/issues/78535#issuecomment-2200268221
    services.printing.drivers = lib.singleton (pkgs.linkFarm "drivers" [
      {
        name = "share/cups/model/BrotherDCP.ppd";
        path = "${cfg-meta.paths.private}/BrotherDCP.ppd";
      }
    ]);

    hardware.printers = {
      ensurePrinters = [
        {
          name = "Brother";
          location = "Home";
          deviceUri = "ipp://printer.home.7mind.io:631/ipp/print";
          # offline printer hack
          model = "BrotherDCP.ppd";
          # Initial setup
          # model = "everywhere";
          # ppdOptions = {
          #   "Duplex" = "DuplexNoTumble";
          # };
        }
      ];
      ensureDefaultPrinter = "Brother";
    };

  };

}
