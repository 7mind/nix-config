{ pkgs, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      # Downgrade wireplumber to 0.5.12 to fix GNOME crash when switching
      # Bluetooth audio to handsfree/HSP/HFP profile.
      # See: https://github.com/NixOS/nixpkgs/issues/475202
      wireplumber = prev.wireplumber.overrideAttrs (old: rec {
        version = "0.5.12";
        src = prev.fetchurl {
          url = "https://gitlab.freedesktop.org/pipewire/wireplumber/-/archive/${version}/wireplumber-${version}.tar.gz";
          hash = "sha256-DOXNSAh7xbVZ1+GpR+ngrbKptvHavZhK+AHzD7ul4Zw=";
        };
      });

      # Fix trezor Python package for Python 3.13
      # https://github.com/NixOS/nixpkgs/pull/455630
      # pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
      #   (python-final: python-prev: {
      #     trezor = python-prev.trezor.overrideAttrs (old: rec {
      #       version = "0.20.0.dev0";
      #       src = prev.fetchPypi {
      #         pname = "trezor";
      #         inherit version;
      #         hash = "sha256-hU2J5TORWU55zoxjfsFPjk4VtNoxmVsjceDVvTKXKxI=";
      #       };
      #       build-system = [ python-prev.hatchling ];
      #       propagatedBuildInputs = (prev.lib.remove prev.trezor-udev-rules (old.propagatedBuildInputs or [])) ++ [
      #         python-prev.noiseprotocol
      #       ];
      #     });
      #   })
      # ];
    })
  ];
}
