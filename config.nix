{
  const = {
    state-version-nixpkgs = "25.05";
    state-version-hm = "25.05";
    state-version-darwin = 6;

    ssh-keys-pavel = [
      ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKA1LYgjfuWSxa1lZRCebvo3ghtSAtEQieGlVCknF8f pshirshov@7mind.io''
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
    # linux-kernel = pkgs.linuxKernel.packageAliases.linux_latest;
    linux-kernel = pkgs.linuxKernel.packages.linux_6_16;
  };


}
