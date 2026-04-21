{ config, cfg-meta, lib, pkgs, ... }:

{
  options = {
    smind.hm.ssh.enable = lib.mkEnableOption "SSH client configuration";
  };

  config = lib.mkIf config.smind.hm.ssh.enable {
    # The `resock` zsh function below shells out to this binary.
    home.packages = lib.mkIf cfg-meta.isLinux [ pkgs.resock ];

    # there is programs.ssh.startAgent = true, but it conflicts with gnome keychain and ssh forwarding
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      matchBlocks."*" = {
        addKeysToAgent = lib.mkIf cfg-meta.isLinux "yes";
        extraOptions = {
          "IgnoreUnknown" = "UseKeychain";
          "UseKeychain" = "yes";
        };
      };
    };

    programs.zsh.envExtra = lib.mkIf (cfg-meta.isLinux && config.services.ssh-agent.enable) ''
      if [ -z "$SSH_AUTH_SOCK" ] || ! [ -S "$SSH_AUTH_SOCK" ]; then
        export SSH_AUTH_SOCK="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent"
      fi
    '';

    # `resock`: manually re-point SSH_AUTH_SOCK at a live agent. The probe
    # logic lives in `pkg/resock/resock.sh` (packaged as the `resock`
    # binary); this shell function is only the `eval` glue that applies the
    # child's `export SSH_AUTH_SOCK=...` output to the current shell.
    # Interactive quirk: `command resock` bypasses function recursion.
    programs.zsh.initContent = lib.mkIf cfg-meta.isLinux ''
      resock() {
        emulate -L zsh
        local out
        if out=$(command resock "$@"); then
          eval "$out"
        fi
      }
    '';
  };
}
