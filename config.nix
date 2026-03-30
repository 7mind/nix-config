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

  cfg-packages = { inputs, pkgs, arch }: {
    jdk-main = pkgs.graalvmPackages.graalvm-ce;
    # Fix amneziawg kernel module build on Linux >= 6.19 (blake2s API change)
    # https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/commit/26f5df04ec47
    linux-kernel = pkgs.linuxKernel.packages.linux_6_19.extend (kfinal: kprev: {
      amneziawg = kprev.amneziawg.overrideAttrs (old: rec {
        version = "1.0.20260329";
        src = pkgs.fetchFromGitHub {
          owner = "amnezia-vpn";
          repo = "amneziawg-linux-kernel-module";
          tag = "v${version}";
          hash = "sha256-csKb8xFnsOYnIbnoqbpIY/R7X8OqF9O9pKC/JZH42pA=";
        };
      });
    });
  };


}
