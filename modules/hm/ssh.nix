{ config, cfg-meta, lib, ... }:

{
  options = {
    smind.hm.ssh.enable = lib.mkEnableOption "SSH client configuration";
  };

  config = lib.mkIf config.smind.hm.ssh.enable {
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
  };
}
