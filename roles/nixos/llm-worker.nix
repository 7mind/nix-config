{ config, lib, cfg-meta, cfg-const, ... }:

let
  cfg = config.smind.roles.server.llm-worker;
  llmSshKeySecretName = "llm-ssh-key";
  ageActive = config.smind.age.active;
  llmSshKeyRekeyFile = "${cfg-meta.paths.secrets}/generic/${llmSshKeySecretName}.age";
  # The .age file must be created out-of-band (operator runs `age -e -r
  # <master-pubkey>` on the freshly-generated private key). Skip the secret
  # binding entirely until that's done so the configuration still
  # evaluates on a freshly-cloned host before key provisioning.
  llmSshKeyAvailable = ageActive && builtins.pathExists llmSshKeyRekeyFile;
in
{
  options.smind.roles.server.llm-worker = {
    enable = lib.mkEnableOption "host intended to be operated by an LLM agent in unattended mode (creates passwordless-sudo `llm` user and a generic agenix-managed SSH key for that user)";

    sshKey.secretName = lib.mkOption {
      type = lib.types.str;
      default = llmSshKeySecretName;
      readOnly = true;
      description = "agenix secret name holding the llm user's SSH private key (encrypted source under `${cfg-meta.paths.secrets}/generic/<name>.age`)";
    };

    sshKey.path = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      readOnly = true;
      default =
        if llmSshKeyAvailable
        then config.age.secrets.${llmSshKeySecretName}.path
        else null;
      description = "runtime path to the decrypted llm SSH private key, or null when the encrypted source under `private/secrets/generic/` is missing (e.g. no-submodules CI build, or pre-key-provisioning bootstrap)";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # Permit the llm user to talk to the nix daemon (required for HM
      # activation, `nix build`, `nix shell`, etc.). Hosts that lock down
      # `nix.settings.allowed-users` to a closed list (e.g. pavel-trx40)
      # would otherwise reject the llm user's daemon connection and the
      # home-manager-llm.service activation fails at first run with
      # "cannot open connection to remote store 'daemon': Connection reset
      # by peer". `llm` already has passwordless sudo via wheel, so
      # promoting to trusted-users is no additional elevation.
      nix.settings.allowed-users = [ "llm" ];
      nix.settings.trusted-users = [ "llm" ];

      smind = {
        security.sudo.wheel-passwordless = lib.mkDefault true;
        security.sudo.wheel-permissive-rules = lib.mkDefault true;

        # Device flashing & adb support so the LLM can program ESP32/Arduino
        # boards and talk to Android devices.
        dev.adb.enable = lib.mkDefault true;
        dev.arduino.enable = lib.mkDefault true;
        dev.arduino.users = [ "llm" ];
      };

      users.groups.llm = { };
      users.users.llm = {
        isNormalUser = true;
        description = "Unattended LLM agent operator";
        home = "/home/llm";
        group = "llm";
        extraGroups = [
          "wheel"
          "ssh-users"
          "podman"
          "ollama"
          "render"
          "video"
          "dialout"
          "plugdev"
          "uucp"
        ];
        openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
      };

      home-manager.users.llm = import "${cfg-meta.paths.users}/llm/hm/home-llm-generic.nix";
    }

    # Age-managed SSH key — only declared when the private submodule and
    # age stack are both available. Public/--no-submodules CI builds skip
    # this branch and the llm user comes up without the agenix key
    # (still usable for SSH via authorized_keys).
    (lib.mkIf llmSshKeyAvailable {
      age.secrets.${llmSshKeySecretName} = {
        rekeyFile = llmSshKeyRekeyFile;
        owner = "llm";
        group = "llm";
        mode = "0400";
      };
    })
  ]);
}
