{ config, lib, pkgs, ... }:

# Unified keyring and SSH agent configuration
# Used by desktop environments (GNOME, COSMIC) for consistent secret/SSH key management

let
  cfg = config.smind.security.keyring;

  # Script to enroll keyring password to TPM
  keyringTpmEnrollScript = pkgs.writeShellScriptBin "keyring-tpm-enroll" ''
    set -euo pipefail

    CRED_PATH="${cfg.tpmUnlock.credentialPath}"
    CRED_DIR="$(dirname "$CRED_PATH")"

    echo "GNOME Keyring TPM Credential Enrollment"
    echo "========================================"
    echo ""
    echo "This will encrypt your keyring password using TPM2."
    echo "The credential will be stored at: $CRED_PATH"
    echo ""

    # Ensure directory exists
    if [ ! -d "$CRED_DIR" ]; then
      echo "Creating credential directory..."
      sudo mkdir -p "$CRED_DIR"
      sudo chmod 755 "$CRED_DIR"
    fi

    # Get password securely
    PASSWORD=$(${pkgs.systemd}/bin/systemd-ask-password "Enter your keyring/login password:")

    if [ -z "$PASSWORD" ]; then
      echo "Error: Empty password provided"
      exit 1
    fi

    # Encrypt using TPM2 without user presence requirement
    # PCRs 0+7 bind to firmware and secure boot state (no user presence needed)
    echo ""
    echo "Encrypting password with TPM..."
    echo -n "$PASSWORD" | sudo ${pkgs.systemd}/bin/systemd-creds encrypt \
      --with-key=tpm2 \
      --tpm2-device=auto \
      --tpm2-pcrs=0+7 \
      --name=keyring-password \
      - "$CRED_PATH"

    sudo chmod 644 "$CRED_PATH"

    echo ""
    echo "Done! Credential enrolled successfully."
    echo "The keyring will be unlocked automatically on next login."
  '';

  # Inner script that runs as the user to unlock keyring
  keyringUnlockInner = pkgs.writeShellScript "keyring-unlock-inner" ''
    CRED_PATH="${cfg.tpmUnlock.credentialPath}"
    CONTROL_SOCKET="$XDG_RUNTIME_DIR/keyring/control"

    # Wait for gnome-keyring control socket
    for i in $(seq 1 10); do
      [ -S "$CONTROL_SOCKET" ] && break
      sleep 0.2
    done
    [ -S "$CONTROL_SOCKET" ] || exit 0

    export GNOME_KEYRING_CONTROL="$XDG_RUNTIME_DIR/keyring"

    # Decrypt password from TPM and unlock keyring
    ${pkgs.systemd}/bin/systemd-creds decrypt "$CRED_PATH" - 2>/dev/null | \
      ${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --unlock >/dev/null 2>&1
  '';

  # PAM script wrapper - runs as root, switches to user
  keyringTpmUnlockScript = pkgs.writeShellScript "keyring-tpm-unlock" ''
    # PAM_USER is set by PAM to the user logging in
    [ -n "$PAM_USER" ] || exit 0

    # Only run for users in tss group
    id -nG "$PAM_USER" 2>/dev/null | ${pkgs.gnugrep}/bin/grep -qw tss || exit 0
    id -nG "$PAM_USER" 2>/dev/null | ${pkgs.gnugrep}/bin/grep -qw users || exit 0

    CRED_PATH="${cfg.tpmUnlock.credentialPath}"
    [ -f "$CRED_PATH" ] || exit 0

    # XDG_RUNTIME_DIR should be set
    [ -n "$XDG_RUNTIME_DIR" ] || exit 0

    # Run the inner script as the actual user
    exec ${pkgs.su}/bin/su "$PAM_USER" -s /bin/sh -c "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR ${keyringUnlockInner}"
  '';
in
{
  options = {
    smind.security.keyring = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable keyring and SSH agent services";
      };

      backend = lib.mkOption {
        type = lib.types.enum [ "gnome-keyring" "none" ];
        default = "gnome-keyring";
        description = "Keyring backend to use";
      };

      sshAgent = lib.mkOption {
        type = lib.types.enum [ "gcr" "standalone" "none" ];
        default = if cfg.backend == "gnome-keyring" then "gcr" else "standalone";
        description = ''
          SSH agent to use:
          - gcr: GCR SSH agent (integrates with gnome-keyring)
          - standalone: Home Manager ssh-agent service
          - none: No SSH agent (user manages manually)
        '';
      };

      displayManagers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "login" ];
        description = "Display managers to enable PAM keyring integration for";
      };

      tpmUnlock = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Enable TPM-based keyring unlock.
            Useful for fingerprint login where password is not available to unlock keyring.
            Requires initial setup: run 'keyring-tpm-enroll' after enabling.
          '';
        };

        credentialPath = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/keyring-tpm/keyring-password";
          description = "Path to store the encrypted keyring credential";
        };
      };
    };
  };

  config = lib.mkIf config.smind.security.keyring.enable (lib.mkMerge [
    # gnome-keyring backend
    (lib.mkIf (config.smind.security.keyring.backend == "gnome-keyring") {
      services.gnome.gnome-keyring.enable = true;
      programs.seahorse.enable = true;

      environment.systemPackages = with pkgs; [
        seahorse
        gcr
      ];

      # PAM integration for auto-unlock on login
      security.pam.services = lib.genAttrs config.smind.security.keyring.displayManagers (_: {
        enableGnomeKeyring = true;
      });
    })

    # GCR SSH agent (requires gnome-keyring)
    (lib.mkIf (config.smind.security.keyring.sshAgent == "gcr") {
      assertions = [{
        assertion = config.smind.security.keyring.backend == "gnome-keyring";
        message = "GCR SSH agent requires gnome-keyring backend";
      }];

      services.gnome.gcr-ssh-agent.enable = true;
    })

    # TPM-based keyring unlock (for fingerprint login)
    (lib.mkIf cfg.tpmUnlock.enable {
      assertions = [{
        assertion = cfg.backend == "gnome-keyring";
        message = "TPM keyring unlock requires gnome-keyring backend";
      }];

      # Enable TPM2 support with user access
      security.tpm2 = {
        enable = true;
        pkcs11.enable = true;
        tctiEnvironment.enable = true;
      };

      # Allow tss group to decrypt credentials without authentication
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "io.systemd.credentials.decrypt" &&
              subject.isInGroup("tss")) {
            return polkit.Result.YES;
          }
        });
      '';

      # Enrollment script
      environment.systemPackages = [ keyringTpmEnrollScript ];

      # Add pam_exec to login session to unlock keyring after pam_gnome_keyring starts the daemon
      # gdm-fingerprint uses "session include login", so we add our rule to login
      # pam_gnome_keyring is at order 12600, we run right after it
      security.pam.services.login.rules.session.keyring-tpm-unlock = {
        order = 12700;
        control = "optional";
        modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
        args = [ "quiet" "${keyringTpmUnlockScript}" ];
      };
    })
  ]);
}
