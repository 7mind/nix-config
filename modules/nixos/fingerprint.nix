{ config, lib, ... }:

# Fingerprint reader support with fprintd
#
# Setup:
#   1. Enable: smind.hw.fingerprint.enable = true
#   2. Enroll fingerprints: fprintd-enroll
#
# Keyring unlock issue:
#   Fingerprint login doesn't provide password to unlock GNOME Keyring.
#   Solution: Enable TPM-based keyring unlock:
#     smind.security.keyring.tpmUnlock.enable = true
#   Then run 'keyring-tpm-enroll' once to seal your password to TPM.
#   After password change, re-run 'keyring-tpm-enroll'.

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
