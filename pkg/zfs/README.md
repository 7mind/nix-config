# OpenZFS Linux 7.3 compatibility patches

`zfs_unstable` (OpenZFS 2.4.4) declares `Linux-Maximum: 7.2` and predates the
Linux 7.3 kernel API changes, while nixpkgs has removed the EOL linux 7.2
kernel. `config.nix` applies these patches to `zfs_unstable` and raises the
META gate so the pinned default kernel (7.3) keeps working with ZFS root
pools.

Source: the `linux-7.3-compat` set by Rob Norris (openzfs/zfs#19032,
backported for 2.4.5-staging in openzfs/zfs#19838), in its hand-backported
2.4.4 form as shipped by Ubuntu 26.10 (zfs-linux 2.4.4-1ubuntu4,
https://git.launchpad.net/ubuntu/+source/zfs-linux/tree/debian/patches?h=import/2.4.4-1ubuntu4).
The 2.4.4 backport differs from the upstream commits: 2.4.4 still carries the
dedicated `iops->create()` detection, so the no-flag probe must also define
`HAVE_IOPS_CREATE_IDMAP` (see the patch headers). Upstream reports the set
builds and passes ZTS on Linux 7.3. Re-validate and drop these patches once a
tagged OpenZFS release supports 7.3 (expected in 2.4.5).

The META gate (`Linux-Maximum: 7.2` → `7.3`) is raised by `config.nix` in
`preConfigure`, after nixpkgs' `postPatch` consistency check — the same
workaround as f8876ff3. Do not vendor `bump-Linux-Maximum-7.3.patch` from the
Ubuntu series: applying it earlier would trip that check.

Application order (Ubuntu series order):

1. `zfs-73-01-iops-create-no-flag.patch` — Linux 7.3: inode_operations.create dropped flag arg
2. `zfs-73-02-bvec-iter-bi-offset.patch` — Linux 7.3: bvec_iter.bi_bvec_done is now bi_offset
3. `zfs-73-03-cpu-feature-enabled.patch` — Linux: use cpu_feature_enabled() instead of static_cpu_has()
4. `zfs-73-04-kthread-init-fs.patch` — Linux 7.3: make host filesystem available to kernel threads
