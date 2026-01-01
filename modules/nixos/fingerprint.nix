{ config, lib, ... }:

{
  options = {
    smind.hw.fingerprint.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable fingerprint reader support with fprintd";
    };
  };

  config = lib.mkIf config.smind.hw.fingerprint.enable {
    services.fprintd.enable = true;

    security.pam.services = {
      login.fprintAuth = lib.mkForce true;
      gdm-fingerprint.fprintAuth = true;
    };
  };
}
