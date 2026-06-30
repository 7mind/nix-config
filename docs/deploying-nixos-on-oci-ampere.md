# Deploying NixOS on Oracle Cloud (OCI) Ampere A1 — definitive guide

A from-scratch, reproducible procedure for getting a NixOS host onto an OCI
free-tier **Ampere A1** instance (`VM.Standard.A1.Flex`, aarch64), plus the full
catalogue of hard lessons that produced it. Written after deploying the `o0`
host in `uk-london-1`, 2026-06.

**Headline:** the method that built o1/o2 two years ago — `nixos-anywhere` +
disko — **no longer works** on this shape (kexec deadlocks the boot volume).
The reliable method now is a **prebuilt custom image**. Build a clean aarch64
qcow2, import it, fix the firmware to UEFI, launch. Everything below stays
within the OCI Always Free allowances.

---

## 0. TL;DR checklist

1. Build a self-contained aarch64 NixOS **qcow2** with `make-disk-image`
   (`partitionTableType="efi"`, systemd-boot, by-label fs, networkd on `enp0s6`,
   `console=ttyAMA0,115200` last, `growPartition`+`autoResize`). **Build on a
   native aarch64 builder.**
2. Upload to Object Storage; `oci compute image import from-object
   --launch-mode PARAVIRTUALIZED --source-image-type QCOW2`.
3. **Fix firmware to UEFI_64** via a per-image capability schema (QCOW2 import
   defaults to BIOS, which aarch64 cannot boot → zero console output).
4. `image-shape-compatibility-entry add` for `VM.Standard.A1.Flex`.
5. Launch from the image on a 100–200 GB boot volume. It boots clean NixOS,
   grows the disk in initrd, reachable over SSH.
6. (managed host) capture the host SSH pubkey → `age.rekey.hostPubkey` →
   `./setup -k <host>` → `./takeover-host <host> root@<ip>` → reboot.
7. **Audit and delete strays** (`instance terminate --wait-for-state SUCCEEDED`,
   not `TERMINATED`) — or you silently blow past the free tier.

---

## 1. Why not `nixos-anywhere`/kexec, and why not `nixos-infect`

### kexec deadlocks the A1 boot volume

Both `nixos-anywhere` (kexec-based) and a hand-rolled `nixos-images` kexec
**hang the instance** during the kexec hand-off. The serial console shows the
box *still on the Ubuntu kernel* with the ext4 journal thread wedged:

```
Kernel command line: ... root=LABEL=cloudimg-rootfs ...     # still Ubuntu
INFO: task jbd2/sda1-8:330 blocked for more than 122 seconds.
INFO: task systemd-journal / kworker / networkd-dispat ... blocked
```

kexec's device-quiesce step deadlocks on the paravirtual virtio-blk boot volume
(`jbd2/sda1` never completes) and the machine locks up — the new kernel never
starts. This holds even though the boot volume is **paravirtualized virtio-blk,
not iSCSI** (no `iscsiadm` session). Kernel at time of writing:
`6.8.0-1049-oracle`. **So every kexec installer is out, including
`nixos-anywhere`'s default flow.** It worked ~2 years ago; it doesn't now.

### `nixos-infect` (in-place co-opt) is a cascade of traps

1. The throwaway *generic* NixOS it builds boots but `systemd-networkd` never
   configures `enp0s6` (`Dependency failed for Wait for Network to be
   Configured`) → unreachable, so you can't push your real config. (Regression
   in the auto-generated config on Oracle; worked years ago.)
2. Run it `NO_REBOOT=y` and push your real closure while still on Ubuntu, and
   the **99 MB Ubuntu cloudimg ESP** overflows — systemd-boot stores
   kernel+initrd in the ESP (`No space left on device`).
3. Switch to GRUB-EFI (stub in ESP, kernels on root) and it fits — but **GRUB
   then boots Ubuntu's leftover kernel** (`root=LABEL=cloudimg-rootfs`), Ubuntu
   services restart-storm. The hybrid bootloader state is unbootable.

Each workaround spawns the next. **Abandon the in-place approaches.**

---

## 2. The procedure that works: a custom image

### 2.1 Build the image (self-contained flake)

Keep it decoupled from your main repo. Minimal flake (`flake.nix`):

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }:
    let
      system = "aarch64-linux";
      cfg = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ({ modulesPath, lib, pkgs, ... }: {
          imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

          boot.loader.systemd-boot.enable = true;
          boot.loader.efi.canTouchEfiVariables = false;   # build env has no efivars;
                                                          # /EFI/BOOT/BOOTAA64.EFI fallback boots on OCI
          boot.growPartition = true;                       # grow root partition in initrd
          boot.initrd.availableKernelModules =
            [ "xhci_pci" "virtio_pci" "virtio_scsi" "virtio_blk" "usbhid" ];

          # ttyAMA0 LAST -> it becomes /dev/console -> full boot visible on OCI console
          boot.kernelParams = [ "nvme.shutdown_timeout=10" "console=ttyS0" "console=tty1" "console=ttyAMA0,115200" ];

          # by-LABEL: make-disk-image labels root "nixos", ESP "ESP"
          fileSystems."/"     = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; autoResize = true; };
          fileSystems."/boot" = { device = "/dev/disk/by-label/ESP";   fsType = "vfat"; options = [ "fmask=0022" "dmask=0022" ]; };

          # Proven Oracle networking (same as o0/o1/o2)
          networking.useNetworkd = true;
          networking.useDHCP = false;
          networking.interfaces.enp0s6.useDHCP = true;

          services.openssh.enable = true;
          services.openssh.settings.PermitRootLogin = "prohibit-password";
          users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... you@host" ];

          nixpkgs.hostPlatform = system;
          system.stateVersion = "24.05";
        }) ];
      };
    in {
      nixosConfigurations.o0base = cfg;
      packages.${system}.image = import "${nixpkgs}/nixos/lib/make-disk-image.nix" {
        pkgs = cfg.pkgs; lib = nixpkgs.lib; config = cfg.config;
        format = "qcow2"; partitionTableType = "efi";
        diskSize = 10240; bootSize = "1024M"; touchEFIVars = false; label = "nixos";
      };
    };
}
```

Build it on a **native aarch64 builder** (configure `/etc/nix/machines`):

```bash
nix build .#packages.aarch64-linux.image --out-link result --builders-use-substitutes
# -> result/nixos.qcow2
```

> `make-disk-image` boots a qemu VM to install the bootloader. Cross-building on
> x86 fully emulates that VM and is unusably slow/flaky. Native aarch64 build
> finishes in minutes.

### 2.2 Import into OCI

```bash
T=$(oci iam compartment list ... )   # or the tenancy OCID from ~/.oci/config
R=uk-london-1
NS=$(oci os ns get --query data --raw-output)
oci os bucket create -c "$T" --name nixos-images               # 20 GB free
oci os object put --bucket-name nixos-images --file result/nixos.qcow2 \
  --name o0.qcow2 --part-size 128

IMG=$(oci compute image import from-object -c "$T" --region "$R" --namespace "$NS" \
  --bucket-name nixos-images --name o0.qcow2 --display-name o0-nixos \
  --launch-mode PARAVIRTUALIZED --source-image-type QCOW2 \
  --operating-system NixOS --operating-system-version unstable \
  --query 'data.id' --raw-output)
# poll until: oci compute image get --image-id "$IMG" --query 'data."lifecycle-state"' == AVAILABLE
```

### 2.3 Fix the firmware to UEFI_64 (the critical, non-obvious step)

A QCOW2 import sets the image firmware to **BIOS**. aarch64/A1 is **UEFI-only**:
a BIOS image won't boot and emits **no console output at all** (the firmware
can't even start). `image import` has no firmware flag. Attach a per-image
**capability schema** pinning firmware to `UEFI_64` (CLI *outputs* kebab-case,
but *input* wants camelCase):

```bash
GSID=$(oci compute global-image-capability-schema list --query 'data[0].id' --raw-output)
GVER=$(oci compute global-image-capability-schema list --query 'data[0]."current-version-name"' --raw-output)
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

oci compute image-capability-schema create -c "$T" --region "$R" --image-id "$IMG" \
  --global-image-capability-schema-version-name "$GVER" \
  --schema-data file://img-schema.json

oci compute image-shape-compatibility-entry add --region "$R" \
  --image-id "$IMG" --shape-name VM.Standard.A1.Flex
```

### 2.4 Launch

```bash
INST=$(oci compute instance launch --region "$R" -c "$T" \
  --availability-domain "<AD>" --display-name o0 \
  --shape VM.Standard.A1.Flex --shape-config '{"ocpus":4,"memoryInGBs":24}' \
  --image-id "$IMG" --subnet-id "<public subnet>" \
  --assign-public-ip true --boot-volume-size-in-gbs 100 \
  --wait-for-state RUNNING --query 'data.id' --raw-output)

# verify firmware (MUST be UEFI_64):
oci compute instance get --instance-id "$INST" --query 'data."launch-options".firmware' --raw-output

# assign IPv6 to the primary VNIC:
VNIC=$(oci compute instance list-vnics --instance-id "$INST" --query 'data[0].id' --raw-output)
oci network ipv6 create --vnic-id "$VNIC" --query 'data."ip-address"' --raw-output
```

The image has your key baked into root (no cloud-init in a plain image, so OCI
metadata keys are NOT injected). It boots, `growPartition`+`autoResize` expand
root to fill the boot volume in initrd, and it's reachable as `root@<ip>`.

### 2.5 Managed-host handoff (agenix-rekeyed hosts)

For a host whose secrets are agenix-rekeyed (like `o0`): the image boots a base
NixOS first, then you flip it to the real host config. Crucially the disk is
already big (initrd grow), so the first activation — which creates the swapfile
and home-manager state — has room.

```bash
ssh root@<ip> cat /etc/ssh/ssh_host_ed25519_key.pub     # persists on the ext4 root
# set age.rekey.hostPubkey = "ssh-ed25519 ..." in the host config
./setup -k o0                                            # rekey secrets (master-key password)
./takeover-host o0 root@<ip>                             # build + nix copy + switch
ssh root@<ip> systemctl reboot                           # apply kernel; verify hostname -> o0
```

Alternative: bake the whole host config into the image (with `growPartition`,
rekey first) and launch the final host directly — at the cost of a rebuild +
re-import per change, and the host-key chicken-and-egg (the image's host key
isn't known until it boots; root SSH access from `cfg-const` is a plain key, not
a secret, so the box is reachable before secrets are rekeyed).

---

## 3. Catalogue of gotchas (each cost real time)

- **Firmware BIOS vs UEFI** — §2.3. Symptom: empty serial console, instance
  `RUNNING` but never reachable. The single biggest time sink.
- **`instance terminate --wait-for-state TERMINATED` is invalid** and makes the
  terminate **silently fail** (it only prints OCI's "try interactive mode"
  footer). Instance terminate is a *work-request* op: valid states are
  `ACCEPTED|IN_PROGRESS|FAILED|SUCCEEDED`. We leaked **6 running A1 instances +
  660 GB of boot volumes** this way before noticing — well over the free cap and
  billing. Use `--wait-for-state SUCCEEDED` (or omit it). **Always re-list
  instances + boot volumes after deploys and delete strays.** (Boot-volume
  *delete* is a lifecycle resource and does take `--wait-for-state TERMINATED`.)
- **`--preserve-boot-volume false` only deletes the volume if the terminate
  actually succeeds.** Detached orphan boot volumes accumulate; delete them
  explicitly: `oci bv boot-volume delete --boot-volume-id <id> --force`.
- **ESP must be ≥ ~512 MB for systemd-boot** (kernel+initrd live there). The
  Ubuntu cloudimg's 99 MB ESP is why the in-place path was doomed; the custom
  image uses a 1 GB ESP.
- **Serial console is `ttyAMA0` on ARM, not `ttyS0`.** OCI `console-history`
  captures `ttyAMA0`; the *last* `console=` becomes `/dev/console` (where
  systemd writes status). Put `console=ttyAMA0,115200` last or the boot is
  invisible. Indispensable for headless debugging.
- **`ping` never works** to these instances from outside (ICMP dropped on the
  path even with the security list allowing it). Judge reachability by SSH /
  TCP-22 / the serial console only.
- **Disk = image size unless you grow it.** `make-disk-image diskSize` is ~10 GB.
  `boot.growPartition=true` + root `autoResize=true` expand it in **initrd**,
  before any service runs — do NOT rely on growing a live disk mid-deploy (a
  live `takeover-host` switch ran the root out of space creating the 4 GB
  swapfile, because growth only happens on reboot). Bake the grow into the
  image/config.
- **Boot volume resize**: `oci bv boot-volume update --size-in-gbs N`, then
  reboot — `growPartition` fills it. Online resize may not be seen by a running
  kernel without a reboot.
- **apt-lock race**: running `nixos-infect` right after boot hits
  `Could not get lock /var/lib/apt/lists/lock`. (Only relevant if you ever touch
  the infect route — you shouldn't.)
- **`oci compute boot-volume-attachment list` requires `--compartment-id`.**

### Client-side: an ssh-agent trap (not OCI's fault)

A wasted cycle came from the *local* setup: a passphrase-encrypted key + a dead
ssh-agent. In `BatchMode`, ssh offers the pubkey (server logs `Server accepts
key`) then can't *sign* → `Permission denied (publickey)`. Looks exactly like a
server-side auth defect but is purely client-side. Before blaming the instance:
`ssh-add -l` must list the key. Fallback: a throwaway unencrypted deploy key.

---

## 4. Free-tier accounting & cleanup discipline

Always-Free allowances (shared across the whole tenancy):

| Resource | Free allowance |
|---|---|
| Ampere A1 compute | **4 OCPU / 24 GB RAM total** (across all A1 instances) |
| Block + boot volume storage | **200 GB total** (across all volumes) |
| Volume backups | 5 free |
| Object Storage | **20 GB** |
| Custom images | free (no charge) |
| Ephemeral public IPs | free; *reserved* IPs can bill if unattached |

Cleanup rules:
- **After every deploy, audit both subscribed regions and all ADs.** A single
  leaked A1 instance is 4 OCPU — instantly over the cap.
- The import **source qcow2** in Object Storage is not needed once the image is
  imported — delete it to reclaim the 20 GB.
- One-shot audit: list `oci compute instance list`, `oci bv boot-volume list`
  (per AD), `oci bv volume list`, `oci bv boot-volume-backup list`,
  `oci os object list`, `oci compute image list`, in **every** region.

---

## 5. Pre-existing networking (this tenancy)

VCN `main` / `public subnet-main` is already dual-stack: IPv4 `10.0.0.0/24` +
IPv6 `2603:c020:c00d:2c00::/64`, route table sends `0.0.0.0/0` and `::/0` to the
internet gateway, security list opens SSH (22) on both stacks. After launch,
assign IPv6 with `oci network ipv6 create --vnic-id <primary>`.

---

## 6. Result

`o0`: `VM.Standard.A1.Flex` 4 OCPU / 24 GB, NixOS 26.11 aarch64, systemd-boot,
200 GB ext4 root (auto-grown), dual-stack — booted from a clean custom image,
no kexec, no co-opt, within the free tier. The image is reusable: relaunch o0 in
minutes, and the same recipe deploys any future OCI Ampere host.
