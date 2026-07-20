{ pkgs, lib, config, options, ... }:
# Before enabling nix-impl = "determinate" on macOS, run Determinate Nix installer
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
    {
      # nixos-raspberrypi's binary cache. The flake input declares this in its
      # own `nixConfig`, but nix ignores `nixConfig` from inputs (only the root
      # flake's is honored), so wire it in explicitly. Applied fleet-wide, not
      # just on the pi hosts: it is harmless on other architectures (nothing
      # matches there), and the trusted key lets any host accept pi paths that
      # were built/signed elsewhere (e.g. cross-built or copied via attic).
      # Merges with the default substituters and the attic cache; the list
      # options append, so this does not clobber other substituter settings.
      nix.settings = {
        substituters = [ "https://nixos-raspberrypi.cachix.org" ];
        trusted-public-keys = [ "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=" ];
      };
    }
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
        connect-timeout = 3;
        keep-going = true;
        eval-cores = 0;
        keep-outputs = true;
        keep-derivations = true;
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
          connect-timeout = 3;
          keep-going = true;
          use-xdg-base-directories = true;
          # Preserve build outputs and derivations so remote-build
          # artifacts (e.g. aarch64 packages built on o1/o2) survive GC.
          # Without these, the GC severs the .drv → output chain and
          # forces full rebuilds on the next deployment.
          keep-outputs = true;
          keep-derivations = true;
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
