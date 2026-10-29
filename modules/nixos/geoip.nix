{ config, lib, pkgs, ... }:

{
  options = {
    smind.services.geoip.enable = lib.mkEnableOption "GeoIP service";

    smind.services.geoip.accountID = lib.mkOption {
      type = lib.types.int;
      description = "GeoIP update account identifier";
    };
    smind.services.geoip.licenseKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Runtime file containing the GeoIP license key";
    };

    smind.services.geoip.key.enable = lib.mkEnableOption "GeoIP license key";
  };

  config = lib.mkIf config.smind.services.geoip.enable {
    services.geoipupdate = {
      enable = true;
      settings = {
        AccountID = config.smind.services.geoip.accountID;

        LicenseKey = lib.mkIf config.smind.services.geoip.key.enable {
          _secret = config.smind.services.geoip.licenseKeyFile;
        };

        DatabaseDirectory = "/var/lib/GeoIP/db";
        EditionIDs = [
          "GeoLite2-ASN"
          "GeoLite2-City"
          "GeoLite2-Country"
        ];
      };
    };

    environment.systemPackages = with pkgs; [
      (writeShellScriptBin "tripc" ''
        set -e
        ${trippy}/bin/trip --geoip-mmdb-file=/var/lib/GeoIP/db/GeoLite2-City.mmdb --tui-geoip-mode=long  --tui-address-mode=both $*
      '')
    ];

  };
}
