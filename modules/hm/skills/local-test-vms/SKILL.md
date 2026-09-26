---
name: local-test-vms
description: >-
  Run local KVM-backed NixOS or Ubuntu test VMs inside the yolo sandbox,
  including persistent or disposable disks, cloud-init, driver and kernel
  testing, and isolated VM-to-VM networking. TRIGGER when a task needs a local
  full-system Linux guest, QEMU/KVM, guest TUN/TAP or driver testing, or two or
  more communicating test VMs. Requires SMIND_SANDBOXED=1,
  YOLO_VM_STATE_DIR, and /dev/kvm. SKIP for containers, remote worker machines,
  and host VM-management tasks.
---

# Local test virtual machines

Use QEMU/KVM directly inside yolo. The guest has its own kernel and may create
TUN/TAP devices, load drivers, change network namespaces, and run privileged
tests without granting those capabilities to the agent on the host.

## Preconditions

Before creating a VM, verify:

```bash
test "${SMIND_SANDBOXED:-}" = 1
test -n "${YOLO_VM_STATE_DIR:-}"
test -d "$YOLO_VM_STATE_DIR" && test -w "$YOLO_VM_STATE_DIR"
test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm
command -v qemu-system-x86_64 qemu-img cloud-localds
```

If a precondition fails, report which capability is absent. Do not attempt to
escape yolo or request broader host device access as a fallback.

## Security boundary

- Guest disks must be regular image files under `$YOLO_VM_STATE_DIR` or the
  current project. Canonicalize both the allowed root and candidate with
  `realpath`, enforce that containment after symlink resolution, and reject the
  candidate unless `test -f` succeeds. Never attach a host block or character
  device.
- Do not pass host directories, sockets, or device nodes into a guest with
  virtiofs, 9p, USB passthrough, or an equivalent mechanism. Transfer inputs
  through a generated seed image or the guest network.
- Do not use QEMU `tap`, `bridge`, or `vhost-vdpa` network backends. The
  sandbox intentionally lacks host `/dev/net/tun` and host network-management
  capability.
- Prefer Unix-domain sockets under a mode-`0700` per-lab directory for shared
  guest networks. Do not use a predictable global socket path.
- Yolo shares the host network namespace. If a guest needs `hostfwd`, bind it
  to `127.0.0.1`, choose a non-conflicting port, and expose no wildcard listener
  unless the user explicitly requested external access.

## Images and state

Create a task-specific directory and use restrictive permissions:

```bash
umask 077
lab="$YOLO_VM_STATE_DIR/<task-name>"
mkdir -p "$lab/images" "$lab/run" "$lab/seed"
```

Keep downloaded or built base images immutable. For a disposable run, create a
qcow2 overlay and delete only that overlay after the test:

```bash
qemu-img info "$lab/images/base.qcow2"
qemu-img create -f qcow2 -F qcow2 \
  -b "$lab/images/base.qcow2" "$lab/images/test.qcow2"
```

Use the actual base format reported by `qemu-img info` as `-F`. Reuse an
overlay only when the test requires persistent guest state.

For Ubuntu, prefer an official cloud image with its published checksum and use
`cloud-localds` to create a seed image from task-specific cloud-init user-data
and metadata. For NixOS, prefer the project's existing NixOS VM or test
derivation; otherwise boot an installer ISO and install into a regular qcow2
image. Do not silently replace a pinned guest release with a newer image.

A typical disk and console configuration is:

```bash
-machine q35,accel=kvm -cpu host -smp 2 -m 2048 \
-drive file="$disk",if=virtio,format=qcow2 \
-display none -serial mon:stdio
```

Specify the actual image format instead of relying on format probing.

## Cloud-init and SSH access

Use a fresh, task-specific SSH key and remove its private key with the
disposable lab. Never put the host's normal private key in a seed image. For
VM-to-VM SSH tests, either provision guest-specific keys or forward an
isolated `ssh-agent` containing only the task-specific key.

Do not assume a password-locked account can authenticate with a public key.
In Alpine cloud images, `lock_passwd: true` causes sshd to reject the account
before checking `authorized_keys`. For an Alpine key-only test account, use a
fresh random password hash whose plaintext is not retained, set
`lock_passwd: false`, and explicitly disable both `PasswordAuthentication` and
`KbdInteractiveAuthentication`. Do not assume `ssh_pwauth: false` disables
keyboard-interactive authentication. Treat this as Alpine-specific unless the
same behaviour has been verified on the guest distribution in use.

Cloud-init modules are commonly once-per-instance. When changing user-data on
a reused overlay, use a new `instance-id` or deliberately run
`cloud-init clean` inside the guest before rebooting; replacing the seed alone
does not guarantee that account or SSH configuration will be reapplied.

Avoid rapid SSH polling during first boot. Repeated pre-authentication or
authentication failures from QEMU's user-network gateway can accumulate
OpenSSH `PerSourcePenalties` and obscure the original failure. Prefer a serial
or guest-agent boot-completion signal; otherwise use bounded exponential
backoff. After the transport becomes reachable, stop retrying repeated
authentication failures and inspect `ssh -vvv`, the guest authentication log,
cloud-init logs, account lock state, and `authorized_keys` contents and modes.

## Networking

### Independent Internet access

QEMU `user` networking is unprivileged and supplies DHCP/NAT, but each QEMU
process gets an independent network. It does not put multiple guests on one
LAN:

```bash
-netdev user,id=wan,net=10.201.1.0/24 \
-device virtio-net-pci,netdev=wan,mac=52:54:00:00:10:01
```

Use a distinct MAC address for every NIC.

### Exactly two guests on one isolated Ethernet segment

Use QEMU's `stream` backend over a private Unix socket. Start the server side
first:

```bash
# Guest A
-netdev stream,id=lan,server=on,addr.type=unix,addr.path="$lab/run/lan.sock" \
-device virtio-net-pci,netdev=lan,mac=52:54:00:00:20:01

# Guest B
-netdev stream,id=lan,server=off,addr.type=unix,addr.path="$lab/run/lan.sock",reconnect-ms=1000 \
-device virtio-net-pci,netdev=lan,mac=52:54:00:00:20:02
```

Assign static guest addresses such as `192.168.77.10/24` and
`192.168.77.11/24`, or run DHCP in one guest. This link carries Ethernet
broadcast and neighbour-discovery traffic; it is not host networking.

### Two or more guests on a shared LAN

Verify `command -v vde_switch`, then run an unprivileged VDE switch without its
TAP option:

```bash
vde_switch \
  --sock "$lab/run/vde" \
  --mode 0600 \
  --dirmode 0700 \
  --nostdin
```

Connect every guest to it with a unique MAC address:

```bash
-netdev vde,id=lan,sock="$lab/run/vde" \
-device virtio-net-pci,netdev=lan,mac=<unique-locally-administered-mac>
```

For shared-LAN guests that also need Internet access, either add a separate
`user` NIC to each guest or make one guest a router with a `user` WAN NIC and a
VDE LAN NIC. Perform forwarding, NAT, TUN/TAP creation, and firewall changes
inside that router guest. When each guest has its own `user` WAN NIC, give the
shared LAN no default route.

## Verification and cleanup

Verify the property the task actually depends on: wait for boot completion,
inspect guest logs, test guest-to-guest reachability over the LAN address, and
run the driver or network operation inside the guest. Merely starting QEMU
proves KVM availability but not guest correctness.

Track the QEMU and VDE process IDs and stop only those processes. Remove stale
Unix sockets, seed images, and disposable overlays created by the task; retain
base images and explicitly requested persistent disks. Report separately what
was boot-tested, what was only configuration-checked, and what remains unknown.
For a persistent overlay, request an in-guest or QMP/ACPI shutdown and wait for
QEMU to exit before sending a termination signal; forced termination can leave
the guest filesystem journal dirty.
