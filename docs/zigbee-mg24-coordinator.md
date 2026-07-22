# raspi5m Zigbee coordinator: Sonoff Dongle Plus MG24 (custom firmware)

Since 2026-07-22 the raspi5m zigbee2mqtt coordinator is a **SONOFF Dongle Plus
MG24** (serial `6c90500956a3ef11800844bd61ce3355`) running a **custom EmberZNet
NCP firmware**. The previous coordinator, an ITead ZBDongle-P (CC2652P/zstack,
serial `3041f4e6a689ef118875b095ef8776e9`), stays plugged into the Pi as a cold
spare. This doc records why the firmware is custom, how to rebuild/reflash it,
and the migration/rollback runbooks.

Vendored artifacts (all in `private/hosts/raspi5m/zigbee/`):

| File | Purpose |
|---|---|
| `mg24-mc26-bc64.gbl` | The deployed firmware image (EmberZNet 8.2.2.0 build 436, 460800 baud) |
| `dpmg24_custom_zigbee_ncp.yaml` | Build manifest that produced it |
| `zigbee-restore.py` | bellows-based commissioning tool (ember sticks) |
| `znp-restore.py` | zigpy-znp-based commissioning tool (the CC2652 spare) |
| `SHA256SUMS` | Integrity for the above |

Network parameters (fixed, mirrored in `cfg-raspi5m.nix`): PAN `0x1a62` (6754),
extended PAN = old coordinator IEEE `00:12:4b:00:31:de:70:db` (config uses the
**little-endian** byte array — herdsman compares raw EZSP order), network key =
the well-known z2m default, channel 15. The MG24 impersonates the original
coordinator IEEE via a one-time-writable manufacturing token, so devices never
re-paired across coordinator swaps.

## Why custom firmware

Stock MG24 firmware compiles `MULTICAST_TABLE_SIZE=8`. z2m sends group commands
*as the coordinator*, which requires a multicast-table slot per group; this
network has ~20 groups, so groups beyond slot 8 failed
(`Failed to register group ... INVALID_STATE`) and wall-button group scenes
broke. The custom build raises:

- `SL_ZIGBEE_MULTICAST_TABLE_SIZE: 26` (the fix that matters)
- `SL_ZIGBEE_BROADCAST_TABLE_SIZE: 64`, `SL_ZIGBEE_APS_UNICAST_MESSAGE_COUNT: 32`
  (headroom matching the old stock firmware)

Do **not** raise `SL_ZIGBEE_KEY_TABLE_SIZE` — 128 provably prevents boot on this
SDK (stock is 1; link keys live in PSA storage now). Harmless: devices rejoin
via the network key.

## Firmware provenance / rebuild

Base: **Nerivec/silabs-firmware-builder**, branch `sisdk-2025.6.2`
(commit `a39373d`, = tag `v2025.6.2-update1`), manifest
`manifests/sonoff/sonoff_dongle-pmg24_zigbee_ncp.yaml` — the only *validated*
config for this dongle: chip `EFR32MG24A420F1536IM48`, UART on **EUSART1**
(TX=PC1, RX=PC2), **460800** baud, software flow control, CTUNE 130.

> The darkxst repo also carries a `dongle_plus_mg24` manifest — it is **wrong**
> (USART0, wrong chip variant, 115200) and produces firmware with a dead UART
> that looks bricked. Do not use it.

To rebuild: fork Nerivec's repo, add the vendored
`dpmg24_custom_zigbee_ncp.yaml` under `manifests/sonoff/`, enable Actions, run
the `Build firmwares` workflow (`workflow_dispatch`) with
`manifest_glob=dpmg24_custom_zigbee_ncp`, download the artifact `.gbl`.
Constraints learned the hard way:

- Stay on the `sisdk-2025.6.2` branch. The 2026.6.x branch emits GBL metadata v3
  (unreadable by universal-silabs-flasher 1.1.0) and EZSP 9.x (too new for the
  pinned bellows/herdsman). **Flashing a newer-SDK build even once "poisons"
  NVM3** — older firmware then fails to boot until NVM3 is cleared.
- Table-size overrides go in the manifest's `configuration:` section, not
  `slcp_defines:` (the latter adds `-D` flags that collide with generated
  headers under `-Werror`).
- A one-off build of this repo's historical fork exists at
  `autopeasant/nerivec-fw` (agent GitHub account) — treat it as disposable; the
  vendored manifest + pinned base commit reproduce it anywhere.

## Flashing / recovery (no BOOT button needed)

The dongle's DTR/RTS lines are wired to reset/boot, so the Gecko bootloader
(v2.4.2) is reachable regardless of application state:

- Reliable interactive path: `npx ember-zli bootloader` → adapter
  `Sonoff Dongle-PMG24` → port by-id → reset **via DTR/RTS** → menu.
  - `Update firmware` → the vendored `.gbl`.
  - `Clear NVM3` (size **32768** for this firmware) — the fix when firmware
    "looks dead" after SDK downgrades or crash-loops; wipes network state only.
- Scriptable path: `universal-silabs-flasher --device <by-id>
  --bootloader-reset rts_dtr flash --firmware <gbl>` (occasionally hangs at
  bootloader entry; retry or use ember-zli).

**Serial-port discipline:** never probe the port (USF/bellows) while z2m is
running or was just using it — overlapping opens wedge the CP2102N bridge
(`cp210x ... status: -110`) and open/close churn can spuriously reset the EFR32
(DTR/RTS wiring). Un-wedge with a per-port USB power cycle:
`uhubctl -l <busnum> -p <devpath> -a cycle` (find bus/port via
`/sys/bus/usb/devices/*/serial`; Pi ports support ppps).

## Coordinator swap runbook (either direction)

1. **Pre-commission the target stick** (non-disruptive, by its own by-id path)
   with the network + spoofed IEEE + a frame counter **floored above the live
   counter** (uint32; tens of millions of margin cost nothing). Ember:
   `zigbee-restore.py <backup.json> <dev> --baudrate 460800 --set-counter N`;
   zstack spare: `znp-restore.py` (115200). Backups live in
   `~/z2m-migration-raspi5m-20260720/` (86 device link keys included).
   A counter *behind* what devices last saw = silent replay rejection.
2. **Flip config** in `cfg-raspi5m.nix`: `services.zigbee2mqtt.adapter`
   (`ember`/`zstack`), udev `ttyZigbee` serial, and for ember also
   `settings.serial.baudrate = 460800` + the pinned `settings.advanced` network
   block (herdsman leaves+reforms on any mismatch). For zstack, remove that block.
3. **Stash the old `coordinator_backup.json`** (`/var/lib/zigbee2mqtt/`) — each
   herdsman adapter crashes on the other stack's backup format. When restoring a
   file there, `chown zigbee2mqtt:zigbee2mqtt` it.
4. Deploy `./setup -n -ncs -s raspi5m`. Expect a **transient z2m crash-loop**:
   the switch restarts z2m before udev repoints `ttyZigbee`. Then
   `udevadm control --reload-rules && udevadm trigger -s tty` and restart
   zigbee2mqtt; the log must show `[INIT TC] Adapter network matches config` →
   `resumed` (never `Forming`).
5. `systemctl start mqtt-controller-force-provision.service` (the provisioner
   verifies scene delivery against `bridge/logging` and retries — exit 0 means
   every scene landed), then test group-scene wall buttons.

Sleepy-device `ROUTE_ERROR_INDIRECT_TRANSACTION_EXPIRY` info lines in the z2m
log are normal parent-buffer expiries for battery devices.
