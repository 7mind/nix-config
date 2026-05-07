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
    let
      # OpenZFS 2.4.1 + Ubuntu 2.4.1-1ubuntu5's cherry-picks for Linux 7.0.
      # Upstream 2.4.1 declares Linux-Maximum: 6.19; these 7 patches are the
      # exact set Canonical ships on 7.0.0-15-generic in Ubuntu 26.04.
      # Vendored from debian/patches/ rather than fetching upstream commit
      # diffs — context-line drift on master makes the raw commit patches
      # fuzz-fail against the 2.4.1 release tree.
      zfsLinux70Patches = [
        ./patches/zfs-2.4.1-linux-7.0/0001-Linux-7.0-explicitly-set-setlease-handler-to-kernel-.patch
        ./patches/zfs-2.4.1-linux-7.0/0002-Linux-7.0-blk_queue_nonrot-renamed-to-blk_queue_rot.patch
        ./patches/zfs-2.4.1-linux-7.0/0003-Linux-7.0-posix_acl_to_xattr-now-allocates-memory.patch
        ./patches/zfs-2.4.1-linux-7.0/0004-Linux-7.0-add-shims-for-the-fs_context-based-mount-A.patch
        ./patches/zfs-2.4.1-linux-7.0/0005-Linux-7.0-also-set-setlease-handler-on-directories-1.patch
        ./patches/zfs-2.4.1-linux-7.0/0006-Linux-7.0-autoconf-Remove-copy-from-user-inatomic-AP.patch
        ./patches/zfs-2.4.1-linux-7.0/0007-Linux-7.0-ensure-LSMs-get-to-process-mount-options.patch
      ];
      patchZfsFor70 = z: z.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ zfsLinux70Patches;
        configureFlags = (old.configureFlags or [ ]) ++ [ "--enable-linux-experimental" ];
        meta = old.meta // { broken = false; };
      });
    in
    {
      jdk-main = pkgs.graalvmPackages.graalvm-ce;
      linux-kernel = pkgs.linuxKernel.packages.linux_7_0.extend (kfinal: kprev: {
        zfs_unstable = patchZfsFor70 kprev.zfs_unstable;
      });
    };


}
