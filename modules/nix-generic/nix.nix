{ pkgs, lib, config, options, ... }:
let
  lixPkgSet = pkgs0: pkgs0.lixPackageSets.latest;
  hasDeterminateOption = options ? determinate && options.determinate ? enable;
  hasDeterminateNixOption = options ? determinateNix && options.determinateNix ? enable;
  isDeterminate = config.smind.nix.nix-impl == "determinate";
  nixPackage =
    if config.smind.nix.nix-impl == "lix"
    then (lixPkgSet pkgs).lix
    else pkgs.nixVersions.stable;
in
{
  options = {
    smind.nix.customize = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Turn on gabage collection, experimental options and other sane defaults";
    };
    smind.nix.nix-impl = lib.mkOption {
      type = lib.types.enum [ "nix" "lix" "determinate" ];
      default = "nix";
      description = "Use a replacement implementation of Nix";
    };
  };

  config = lib.mkMerge [
    (lib.optionalAttrs hasDeterminateOption {
      determinate.enable = isDeterminate;
    })
    (lib.optionalAttrs hasDeterminateNixOption {
      determinateNix.enable = isDeterminate;
    })
    (lib.mkIf isDeterminate {
      smind.nix.customize = lib.mkForce false;

      nixpkgs.config.allowUnfree = true;

      nix.settings = {
        connect-timeout = 5;
        keep-going = true;
        eval-cores = 0;
      };

      environment.systemPackages = [ pkgs.fh ];
    })
    (lib.mkIf (config.smind.nix.customize && !isDeterminate) {
      nix = lib.optionalAttrs (!isDeterminate) {
        package = nixPackage;
      } // {
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
          # unsupported on Lix
          download-buffer-size = lib.mkIf (config.smind.nix.nix-impl != "lix") (1024 * 1024 * 1024); # 1 GiB;
        };
      };
      nixpkgs.config.allowUnfree = true;
      nixpkgs.overlays = lib.mkIf (config.smind.nix.nix-impl == "lix") [
        (final: prev: {
          inherit (lixPkgSet prev)
            nixpkgs-review
            nix-eval-jobs
            nix-fast-build
            colmena;
        })
      ];
    })
  ];
}
