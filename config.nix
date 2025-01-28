{
  const = {
    state-version-nixpkgs = "25.05";
    state-version-hm = "25.05";

    ssh-keys-pavel = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKA1LYgjfuWSxa1lZRCebvo3ghtSAtEQieGlVCknF8f pshirshov@7mind.io"
    ];
  };

  cfg-packages = { inputs, pkgs, arch }: {
    jdk-main = pkgs.graalvm-ce;
    linux-kernel = pkgs.linuxKernel.packageAliases.linux_latest;
    # linux-kernel = pkgs.linuxKernel.packages.linux_6_13;
  };
}
