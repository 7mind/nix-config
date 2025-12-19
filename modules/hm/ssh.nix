{ config, cfg-meta, lib, ... }:

{
  options = {
    smind.hm.ssh.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SSH client configuration";
    };
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
  };
}
