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
      gnuradio
    ];

    # Add user to 'plugdev' group if they want to use rtl-sdr without root
    # NixOS's hardware.rtl-sdr.enable usually handles udev rules and may use 'rtlsdr' group
    # but some tools expect 'plugdev'. Let's ensure the user is in the right group.
    users.groups.plugdev = { };
  };
}
