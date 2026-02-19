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

      # Update codex: 0.92.0 -> 0.98.0
      # Uses importCargoLock instead of fetchCargoVendor because a git
      # dependency (rules_rust) contains Cargo.toml files with unstable
      # features that break fetchCargoVendor's cargo metadata invocation.
      codex = prev.codex.overrideAttrs (old: rec {
        version = "0.98.0";
        src = prev.fetchFromGitHub {
          owner = "openai";
          repo = "codex";
          tag = "rust-v${version}";
          hash = "sha256-rP5Qo70n5lNrdR6ycE63VObLwcMNRlk8sY/kuJ4Qw9Y=";
        };
        sourceRoot = "${src.name}/codex-rs";
        cargoDeps = prev.rustPlatform.importCargoLock {
          lockFile = "${src}/codex-rs/Cargo.lock";
          outputHashes = {
            "crossterm-0.28.1" = "sha256-6qCtfSMuXACKFb9ATID39XyFDIEMFDmbx6SSmNe+728=";
            "nucleo-0.5.0" = "sha256-Hm4SxtTSBrcWpXrtSqeO0TACbUxq3gizg1zD/6Yw/sI=";
            "ratatui-0.29.0" = "sha256-HBvT5c8GsiCxMffNjJGLmHnvG77A6cqEL+1ARurBXho=";
            "runfiles-0.1.0" = "sha256-uJpVLcQh8wWZA3GPv9D8Nt43EOirajfDJ7eq/FB+tek=";
            "tokio-tungstenite-0.28.0" = "sha256-vJZ3S41gHtRt4UAODsjAoSCaTksgzCALiBmbWgyDCi8=";
            "tungstenite-0.28.0" = "sha256-CyXZp58zGlUhEor7WItjQoS499IoSP55uWqr++ia+0A=";
          };
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
