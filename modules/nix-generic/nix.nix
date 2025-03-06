{ pkgs, lib, config, ... }: {
  options = {
    smind.nix.customize = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Turn on gabage collection, experimental options and other sane defaults";
    };
  };

  config = lib.mkIf config.smind.nix.customize {
    nix = {
      package = pkgs.nixVersions.stable;
      gc.automatic = true;
      gc.options = "--delete-older-than 8d";
      extraOptions = ''
        experimental-features = nix-command flakes
      '';
      optimise.automatic = true;
      settings = {
        connect-timeout = 1;
        keep-going = true;
        use-xdg-base-directories = true;
      };
    };

    nixpkgs.config.allowUnfree = true;
  };

}
