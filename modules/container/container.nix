{ cfg-meta, cfg-const, lib, pkgs, ... }:

{
  imports = [
    # ../../consts.nix
    "${cfg-meta.paths.modules}/nixos/ssh.nix"
  ];

  # nspawn containers re-evaluate nixpkgs fresh and do not inherit the
  # host's overlays. Mirror the two host-side `intel-compute-runtime`
  # overrides (see `globals.nix` for the full rationale): the 26.18
  # bump *and* the patchelf that puts intel-graphics-compiler into the
  # Level Zero driver's RPATH so NEO can dlopen `libigdfcl.so.2` /
  # `libigc.so.2` at eager device init. Without the RPATH fix every
  # container's L0 path aborts at `gmm_helper/resource_info.cpp:15`
  # — the symptom the OpenCL-UR-bypass quirks were compensating for.
  # Dormant on containers that don't reference
  # `pkgs.intel-compute-runtime`.
  nixpkgs.overlays = [
    (final: prev: {
      ghostty-terminfo = prev.callPackage ../../pkg/ghostty-terminfo { };

      intel-compute-runtime = prev.intel-compute-runtime.overrideAttrs (oldAttrs: rec {
        version = "26.18.38308.1";
        src = prev.fetchFromGitHub {
          owner = "intel";
          repo = "compute-runtime";
          tag = version;
          hash = "sha256-539TqwzPhclEpyxrwRB0DBLCAgM8JojdshvhNp0jeKU=";
        };
        postFixup = (oldAttrs.postFixup or "") + ''
          for lib in "$drivers"/lib/libze_intel*.so* ; do
            [ -L "$lib" ] && continue
            patchelf --set-rpath ${
              prev.lib.makeLibraryPath [
                prev.intel-gmmlib
                prev.intel-graphics-compiler
                prev.libva
                prev.stdenv.cc.cc
              ]
            } "$lib"
          done
        '';
      });
    })
  ];

  smind = {
    ssh.mode = "safe";
  };

  users = {
    users.root = {
      openssh.authorizedKeys.keys = cfg-const.ssh-keys-pavel;
      #password = "nixos";
    };
  };

  system.stateVersion = cfg-meta.state-version-system;

  # Containers have no use for the NixOS options manual / manpages.
  # Skips rendering work at build time and shaves a few MB per container.
  # (Doesn't measurably affect eval time — option-doc generation is lazy
  # and toplevel doesn't force it — but it's free hygiene.)
  documentation.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;

  environment.systemPackages = [
    pkgs.ghostty-terminfo
  ];

  services.openssh = {
    settings = {
      PermitRootLogin = lib.mkDefault "prohibit-password";
      AuthorizedKeysFile =
        "/etc/ssh/authorized_keys.d/%u .ssh/authorized_keys .ssh/authorized_keys2";
    };
  };

  networking = {
    # Use systemd-resolved inside the container
    # Workaround for bug https://github.com/NixOS/nixpkgs/issues/162686
    useHostResolvConf = false;

    enableIPv6 = false;
    useNetworkd = true;
    useDHCP = false;
    dhcpcd.enable = false;
  };

  systemd.network.enable = true;
  systemd.network.wait-online.enable = false;

  services.resolved = {
    enable = true;
    settings = {
      Resolve = {
        Cache = "no-negative";
        LLMNR = "false";
      };
    };
  };
}
