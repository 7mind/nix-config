{
  const = {
    state-version-nixpkgs = "25.05";
    state-version-hm = "26.05";
    state-version-darwin = 6;

    ssh-keys-pavel = [
      ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKA1LYgjfuWSxa1lZRCebvo3ghtSAtEQieGlVCknF8f pshirshov@7mind.io''
      ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMxs2z8cQYA3VlCbVJBLLIAcQTV9JXJZN5oEtffKyTWe pshirshov@7mind.io:llm''
    ];

    ssh-keys-nix-builder = [
      ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJM1TV44pHGx0MxbHPRr+AkkP6k1ppS2pYJdvJGPVQsR builder''
    ];

    universal-aliases = {
      "j" = "z"; # zoxide
      lsblk =
        "lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT,FSUSE%,WWN,SERIAL,MODEL";
      watch = "viddy";
      tree = "lsd --tree";
      # ls = "lsd -lh --group-directories-first";
      la = "lsd -lha --group-directories-first";

      myip = "curl -4 ifconfig.co";
      myip4 = "curl -4 ifconfig.co";
      myip6 = "curl -6 ifconfig.co";
    };
  };

  cfg-packages = { inputs, pkgs, arch }:
    {
      jdk-main = pkgs.graalvmPackages.graalvm-ce;
      linux-kernel = pkgs.linuxKernel.packages.linux_7_1.extend (_: prev: {
        # OpenZFS 2.4.3 contains the Linux 7.1 compatibility changes, but its
        # release metadata still declares 7.0 as the maximum supported kernel.
        # https://github.com/openzfs/zfs/pull/18682
        zfs_unstable = prev.zfs_unstable.overrideAttrs (oldAttrs: {
          preConfigure = ''
            substituteInPlace META \
              --replace-fail "Linux-Maximum: 7.0" "Linux-Maximum: 7.1"
          '' + oldAttrs.preConfigure;
          meta = oldAttrs.meta // { broken = false; };
        });

        # Linux 7.1 removed ipv6_stub from the public networking API.
        amneziawg = prev.amneziawg.overrideAttrs (oldAttrs: {
          patches = (oldAttrs.patches or [ ]) ++ [
            (pkgs.fetchpatch {
              url = "https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/commit/2a764691e22f15770aa1551ecae12c0431dbd651.patch";
              stripLen = 1;
              hash = "sha256-oj6iPKTKpuRJjd8QZS5dOVyHo2y/rrtY+Q0RLqSvwzg=";
            })
          ];
        });
      });
    };


}
