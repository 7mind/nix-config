{
  const = {
    state-version-nixpkgs = "25.05";
    state-version-hm = "26.05";
    state-version-darwin = 6;

    ssh-keys-pavel = [
      ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKA1LYgjfuWSxa1lZRCebvo3ghtSAtEQieGlVCknF8f pshirshov@7mind.io''
      ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMxs2z8cQYA3VlCbVJBLLIAcQTV9JXJZN5oEtffKyTWe pshirshov@7mind.io:llm''
    ];

    # Public half of the agenix-managed `llm-ssh-key` secret (declared in
    # roles/nixos/llm-worker.nix). Agents on other hosts hold the private
    # half (at /run/agenix/llm-ssh-key) and log in to the `llm` user with
    # it. This is a separate identity from the `pshirshov@7mind.io:llm`
    # key above despite that key's comment.
    ssh-keys-llm = [
      ''ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN3Dgq0nNzCQGcODYnw44WFYHNS+AwMS6S+H5cwIzvFJ llm-ssh-key''
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
      la = "lsd -lha --group-directories-first";

      myip = "curl -4 ifconfig.co";
      myip4 = "curl -4 ifconfig.co";
      myip6 = "curl -6 ifconfig.co";
    };
  };

  cfg-packages = { inputs, pkgs, arch }:
    {
      jdk-main = pkgs.graalvmPackages.graalvm-ce;
      # linux 7.2 is EOL and removed from nixpkgs; OpenZFS 2.4.4 still declares
      # Linux-Maximum: 7.2 and predates the 7.3 kernel API changes. Carry the
      # upstream-tested 7.3 compat set (pkg/zfs/README.md) and raise the META
      # gate like the previous 7.0 → 7.1 workaround (f8876ff3).
      linux-kernel = pkgs.linuxKernel.packages.linux_7_3.extend (_: prev: {
        zfs_unstable = prev.zfs_unstable.overrideAttrs (oldAttrs: {
          patches = oldAttrs.patches ++ [
            ./pkg/zfs/patches/zfs-73-01-iops-create-no-flag.patch
            ./pkg/zfs/patches/zfs-73-02-bvec-iter-bi-offset.patch
            ./pkg/zfs/patches/zfs-73-03-cpu-feature-enabled.patch
            ./pkg/zfs/patches/zfs-73-04-kthread-init-fs.patch
          ];
          preConfigure = ''
            substituteInPlace META \
              --replace-fail "Linux-Maximum: 7.2" "Linux-Maximum: 7.3"
          '' + oldAttrs.preConfigure;
          meta = oldAttrs.meta // { broken = false; };
        });
      });
    };


}
