{ config, lib, ... }:

{
  options = {
    smind.hm.ssh.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.ssh.enable {
    programs.ssh = {
      enable = true;
      addKeysToAgent = "yes";
      extraConfig = ''
        IgnoreUnknown UseKeychain
        UseKeychain yes
      '';
    };
  };
}
