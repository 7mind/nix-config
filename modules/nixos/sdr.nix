{ config, lib, pkgs, ... }:
let
  cfg = config.smind.sdr;
in
{
  options.smind.sdr = {
    enable = lib.mkEnableOption "SDR (Software Defined Radio) tools and hardware support";

    analyze = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install analysis and reverse engineering tools (URH, inspectrum, gnuradio)";
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.rtl-sdr.enable = true;

    environment.systemPackages = with pkgs; [
      rtl-sdr
      rtl_433
      gqrx
      sdrangel
    ] ++ lib.optionals cfg.analyze [
      urh
      inspectrum
      # gnuradio  # disabled: pyqtgraph 0.14.0 SVG exporter tests fail (upstream bug)
    ];

    # hardware.rtl-sdr.enable uses the 'rtlsdr' group, but some tools expect 'plugdev'.
    users.groups.plugdev = { };
  };
}
