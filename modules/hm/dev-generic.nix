{ config, lib, pkgs, ... }:

{
  options = {
    smind.hm.dev.generic.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "";
    };
  };

  config = lib.mkIf config.smind.hm.dev.generic.enable {
    home.sessionVariables = {
      DOTNET_CLI_TELEMETRY_OPTOUT = "1";
    };

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
      config = {
        whitelist.prefix = [ "~/work/safe" ];
      };
    };

    home.packages = with pkgs; [
      slack
      gitFull
    ];
  };


}
