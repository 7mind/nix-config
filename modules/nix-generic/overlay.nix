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
    })
  ];
}
