# Deploying NixOS on Oracle Cloud (OCI) Ampere A1 — what works, what doesn't, and why

Hard-won notes from deploying the `o0` host onto an OCI free-tier Ampere
(`VM.Standard.A1.Flex`, aarch64) in uk-london-1, 2026-06. The headline: the
method that built o1/o2 two years ago (`nixos-anywhere` + disko) **no longer
works** on this shape, and the reliable replacement is a **prebuilt custom
image**. This documents the dead ends with evidence so we don't repeat them.

---

## TL;DR — the procedure that works

1. Build a self-contained aarch64 NixOS **qcow2** with `make-disk-image`
   (`partitionTableType = "efi"`, systemd-boot, by-label filesystems,
   `networking` via networkd on `enp0s6`, `console=ttyAMA0,115200` last,
   `boot.growPartition = true` + root `autoResize = true`).
   **Build it on a native aarch64 builder** — emulated build is unbearably slow.
2. Upload the qcow2 to **Object Storage**, then
   `oci compute image import from-object --launch-mode PARAVIRTUALIZED
   --source-image-type QCOW2`.
3. **Critical:** the QCOW2 import sets firmware to **BIOS**, but A1/aarch64 is
   **UEFI-only**. Create a per-image **capability schema** pinning
   `Compute.Firmware = UEFI_64`. Without this the instance produces *zero*
   console output and never boots.
4. Mark the image compatible with `VM.Standard.A1.Flex`
   (`oci compute image-shape-compatibility-entry add`).
5. Launch from the image on A1. It boots clean NixOS, reachable over SSH.
6. (For a managed host like `o0`) capture the live host SSH pubkey →
   `age.rekey.hostPubkey` → `./setup -k o0` → `./takeover-host o0 root@<ip>` →
   reboot (grows the disk, applies real secrets).

Everything above stays within Always Free (custom images are free; the qcow2
counts against the 20 GB Object Storage allowance; A1 4 OCPU/24 GB and a
≤200 GB boot volume are free).

---

## The core problem: kexec deadlocks the A1 boot volume

Both `nixos-anywhere` and a hand-rolled `nixos-images` kexec **hang the
instance** during the kexec hand-off. After `kexec --load` + execute, the
serial console shows the box *still on the Ubuntu kernel* with the ext4
journal thread wedged:

```
Kernel command line: ... root=LABEL=cloudimg-rootfs ...   <- still Ubuntu
INFO: task jbd2/sda1-8:330 blocked for more than 122 seconds.
INFO: task systemd-journal / kworker / networkd-dispat ... blocked
```

kexec's device-quiesce step deadlocks on the paravirtual virtio-blk boot
volume (the `jbd2/sda1` ext4 journal never completes), and the whole machine
locks up — SSH dies, the new kernel never starts. This is the failure the
`takeover-o0` script header warned about ("kexec is unsafe on Oracle"), and it
holds even though the boot volume is **paravirtualized virtio-blk, not iSCSI**
(no `iscsiadm` session). The current Ubuntu kernel is `6.8.0-1049-oracle`.

**Consequence:** every kexec-based installer is out — including
`nixos-anywhere` in its default flow. o1/o2 were built with `nixos-anywhere` +
disko ~2 years ago, when kexec still worked on this shape. Don't assume it
still does.

## Why `nixos-infect` (in-place co-opt) is also a trap here

With kexec gone, the obvious fallback is `nixos-infect` (builds NixOS into the
running Ubuntu rootfs, reboots via GRUB — no kexec). It chains into a series of
problems:

1. **Generic infect networking is broken on current nixpkgs.** The throwaway
   generic NixOS boots but `systemd-networkd` never configures `enp0s6`
   (`Dependency failed for Wait for Network to be Configured`) → no IP →
   unreachable, so you can't push the real config. (This worked years ago; it's
   a regression in the auto-generated generic config on Oracle.)
2. You can dodge that by running `nixos-infect` with `NO_REBOOT=y` and pushing
   the *real* host closure while still on Ubuntu — but then the **99 MB Ubuntu
   cloudimg ESP** bites you: systemd-boot stores the kernel+initrd in the ESP
   and overflows it (`OSError: [Errno 28] No space left on device`).
3. Switch that host to **GRUB-EFI** (stub in the ESP, kernels on the ext4 root)
   and it fits — but now **GRUB boots Ubuntu's leftover kernel** instead of
   NixOS (`root=LABEL=cloudimg-rootfs`, Ubuntu services in a restart storm).
   The in-place co-opt leaves Ubuntu's GRUB/kernels on the same disk and the
   hybrid bootloader state is unbootable.

Net: the co-opt path is a cascade of workarounds, each creating the next
problem. Abandon it.

## The fix: a clean prebuilt custom image

Skip in-place conversion entirely. Build a disk image with a clean layout and
hand it to OCI. No kexec, no co-opt, no leftover Ubuntu.

### Building the image

A self-contained flake (nixpkgs only — keep it decoupled from the main repo):

```nix
packages.aarch64-linux.image = import "${nixpkgs}/nixos/lib/make-disk-image.nix" {
  pkgs = cfg.pkgs; lib = nixpkgs.lib; config = cfg.config;
  format = "qcow2";
  partitionTableType = "efi";   # GPT: root label "nixos", ESP label "ESP"
  diskSize = 10240;             # MiB; grown at boot to fill the boot volume
  bootSize = "1024M";           # roomy ESP for systemd-boot
  touchEFIVars = false;         # rely on /EFI/BOOT/BOOTAA64.EFI fallback
};
```

The NixOS config inside it must have:

- `boot.loader.systemd-boot.enable = true;`
  `boot.loader.efi.canTouchEfiVariables = false;` (no efivars at build time;
  the universal `BOOTAA64.EFI` fallback is what OCI's firmware boots).
- `fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4";
  autoResize = true; };` and `fileSystems."/boot" = { device =
  "/dev/disk/by-label/ESP"; fsType = "vfat"; ... };` — **by-label**, because
  `make-disk-image` labels the partitions, and UUIDs aren't known until build.
- `boot.growPartition = true;` — grow the root partition + ext4 to fill a
  larger boot volume in initrd. The image is small (10 GB); launch onto a
  bigger boot volume and it expands on first boot.
- **Networking that actually works on Oracle**: networkd DHCP on `enp0s6`
  (same as o0/o1/o2). The minimal default isn't guaranteed:
  ```nix
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.interfaces.enp0s6.useDHCP = true;
  ```
- `boot.kernelParams` ending with `console=ttyAMA0,115200` (see "console"
  gotcha below).
- Your SSH key in `users.users.root.openssh.authorizedKeys.keys` (no cloud-init
  in a plain image → OCI metadata keys are NOT injected; bake the key in).

**Build on a native aarch64 builder.** `make-disk-image` boots a qemu VM to
install the bootloader; cross-building on x86 fully emulates that VM and is
glacial/flaky. With remote aarch64 builders configured (`/etc/nix/machines`),
`nix build .#packages.aarch64-linux.image` offloads and finishes in minutes.

### Importing into OCI

```bash
NS=$(oci os ns get --query data --raw-output)
oci os bucket create -c "$T" --name nixos-images        # within 20 GB free
oci os object put --bucket-name nixos-images --file nixos.qcow2 --name o0.qcow2 --part-size 128
IMG=$(oci compute image import from-object -c "$T" --namespace "$NS" \
  --bucket-name nixos-images --name o0.qcow2 --display-name o0-nixos \
  --launch-mode PARAVIRTUALIZED --source-image-type QCOW2 \
  --operating-system NixOS --operating-system-version unstable \
  --query 'data.id' --raw-output)
# wait for lifecycle-state AVAILABLE (import takes ~10-20 min)
```

### The firmware gotcha (this is the one that wastes hours)

A QCOW2 import defaults the image firmware to **BIOS**. aarch64/A1 hardware is
**UEFI-only** — a BIOS image won't boot and emits **no console output at all**
(the firmware can't even start). `oci compute image import` has no firmware
flag (only `--launch-mode` / `--source-image-type`).

Fix: attach a **per-image capability schema** that pins firmware to UEFI_64.
Derive it from the global schema (note: CLI *outputs* kebab-case but the API
*input* wants camelCase — `descriptorType`, `defaultValue`):

```bash
GVER=$(oci compute global-image-capability-schema list \
        --query 'data[0]."current-version-name"' --raw-output)
oci compute global-image-capability-schema-version get \
  --global-image-capability-schema-id "$GSID" \
  --global-image-capability-schema-version-name "$GVER" \
  --query 'data."schema-data"' --output json > global-schema.json

jq 'to_entries
   | map(.value |= ({descriptorType:.["descriptor-type"], source:.source}
       + (if has("default-value") then {defaultValue:.["default-value"]} else {} end)
       + (if has("values") then {values:.values} else {} end)))
   | from_entries
   | .["Compute.Firmware"] = {descriptorType:"enumstring", source:"IMAGE",
       values:["UEFI_64"], defaultValue:"UEFI_64"}' \
   global-schema.json > img-schema.json

oci compute image-capability-schema create -c "$T" --image-id "$IMG" \
  --global-image-capability-schema-version-name "$GVER" \
  --schema-data file://img-schema.json

oci compute image-shape-compatibility-entry add --image-id "$IMG" \
  --shape-name VM.Standard.A1.Flex
```

Verify after launch — the instance's `launch-options.firmware` must read
`UEFI_64`. Then the image boots clean NixOS and answers on `root@`.

---

## Smaller gotchas that each cost time

- **Serial console is `ttyAMA0` on ARM, not `ttyS0`.** OCI `console-history`
  captures `ttyAMA0`. The `oracle-cloud` role sets only `console=ttyS0` /
  `console=tty1`, so the host's boot is invisible on the OCI console, and the
  *last* `console=` becomes `/dev/console` (where systemd writes status). Add
  `boot.kernelParams = lib.mkAfter [ "console=ttyAMA0,115200" ];` so ttyAMA0 is
  last → full boot visible. Invaluable for debugging headless boots.
- **`ping` never works** to these instances from outside (ICMP is dropped on
  the path even with the security list allowing it). Judge reachability by
  SSH/TCP-22 and the serial console — never by ping.
- **`apt` lock race.** Running `nixos-infect` immediately after first boot hits
  `Could not get lock /var/lib/apt/lists/lock` (cloud-init still installing) →
  `ERROR: Missing bzcat`. Wait: `cloud-init status --wait`, poll `fuser` on the
  apt/dpkg locks, then `apt-get -y install bzip2`.
- **Nix isn't on the non-interactive PATH after `nixos-infect`.** `nix copy
  --to ssh://root@host` fails with `nix-store: command not found` because the
  Nix profile is only sourced for login shells. Symlink
  `/nix/var/nix/profiles/system/sw/bin/{nix,nix-store,nix-env}` into
  `/usr/bin` first. (Only relevant if you ever go the infect route.)
- **`instance terminate --wait-for-state` is a footgun.** Instance terminate is
  a *work-request* operation: valid `--wait-for-state` values are
  `ACCEPTED|IN_PROGRESS|FAILED|SUCCEEDED` — **NOT `TERMINATED`**. Passing
  `--wait-for-state TERMINATED` makes the whole command error out silently
  (it just prints OCI's "try interactive mode" footer) and the instance is
  **never terminated**. We leaked SIX running A1 instances + six boot volumes
  (≈660 GB, well over the 200 GB free cap) this way before noticing. Use
  `--wait-for-state SUCCEEDED`, or omit the flag (it returns a work-request id).
  **Always re-list instances + boot volumes after a deploy** and delete strays —
  `--preserve-boot-volume false` only deletes the volume *if the terminate
  actually succeeds*. Boot-volume *delete* (a lifecycle resource, not a
  work-request) does take `--wait-for-state TERMINATED`.
- **Boot-volume CLI quirks.** `oci compute boot-volume-attachment list`
  requires `--compartment-id`. Online-resize the boot volume
  (`oci bv boot-volume update --size-in-gbs 100`) before the host's first boot;
  `boot.growPartition` then fills it.
- **Disk too small.** `make-disk-image diskSize` is the *image* size (~10 GB).
  `boot.growPartition = true` + root `autoResize = true` grow it to the boot
  volume on first boot — otherwise you're stuck at 10 GB.

## Client-side: SSH that bit us (not OCI's fault)

Independent of OCI, a wasted cycle came from the *local* SSH setup: the key was
passphrase-encrypted and the ssh-agent was down. In `BatchMode`, ssh offers the
public key (server logs `Server accepts key`) but then can't *sign* — no agent,
no passphrase — yielding `Permission denied (publickey)`. This looks exactly
like a server-side auth defect but is purely client-side. Before blaming the
instance: `ssh-add -l` must list the key. Fallback: a throwaway unencrypted
deploy key.

## Free-tier accounting

- **Custom images**: free (OCI does not bill custom image storage).
- **The qcow2 in Object Storage**: counts against the **20 GB** Always Free
  Object Storage. Delete the source object after import to reclaim it — the
  image keeps working.
- **Instance**: `VM.Standard.A1.Flex` up to **4 OCPU / 24 GB** is the Always
  Free Ampere allocation.
- **Boot volume**: within the **200 GB** Always Free block-storage allowance.

## Networking that already exists (this tenancy)

VCN `main` / `public subnet-main` is already dual-stack: IPv4 `10.0.0.0/24` +
IPv6 `2603:c020:c00d:2c00::/64`, route table sends both `0.0.0.0/0` and `::/0`
to the internet gateway, and the security list opens SSH (22) on both stacks.
After launch, assign IPv6 with `oci network ipv6 create --vnic-id <primary>`.

---

## Appendix: managed-host handoff (agenix)

For a host like `o0` whose secrets are agenix-rekeyed, the image boots a base
NixOS first; then:

1. Capture the live host key: `cat /etc/ssh/ssh_host_ed25519_key.pub` (it
   persists on the ext4 root across the takeover).
2. Set `age.rekey.hostPubkey = "ssh-ed25519 ...";` in the host config.
3. `./setup -k o0` to rekey secrets for that pubkey (building with the dummy
   recipient would otherwise fail activation at runtime).
4. `./takeover-host o0 root@<ip>` to build + `nix copy` + switch.
5. Reboot — applies the new kernel and grows the disk via `growPartition`.

Alternatively, bake the whole host config into the image (add `growPartition` +
`autoResize`, rekey first) so launching gives the final host directly — at the
cost of a rebuild + re-import per change.
