{ config, lib, pkgs, ... }:

# Unified keyring and SSH agent configuration
# Used by desktop environments (GNOME, COSMIC) for consistent secret/SSH key management

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
        default = if config.smind.security.keyring.backend == "gnome-keyring" then "gcr" else "standalone";
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
  ]);
}
