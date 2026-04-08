# hue-setup tests

End-to-end tests for `pkg/hue-setup/hue_setup.py` against a fake
zigbee2mqtt bridge.

Each test boots a private mosquitto on an ephemeral port and a
`FakeZ2m` handler that subscribes to `zigbee2mqtt/bridge/request/#` and
`zigbee2mqtt/+/set`, then drives `hue_setup.reconcile` through a real
`Z2mClient`. The handler maintains an in-memory inventory of groups,
members, and scenes, mirrors only the parts of z2m's behavior that
hue_setup actually relies on, and republishes `bridge/groups`
(retained) on every mutation so the next `fetch_groups` call sees a
fresh snapshot.

## Running

```
cd tests/hue-setup
nix-shell --run pytest
```

## What's covered

| Test | Property checked |
|---|---|
| `test_additive_creates_missing_group` | New group + members are created from an empty inventory |
| `test_skip_when_group_already_matches` | No publishes when state already matches the config |
| `test_dry_run_publishes_nothing` | `--dry-run` exits without mutating any state |
| `test_additive_adds_missing_member` | A new member added to an existing group |
| `test_additive_does_not_remove_extra_member` | Without `--prune`, extras are left in place |
| `test_prune_removes_extra_member` | `--prune` deletes members not in the config |
| `test_prune_removes_stale_group` | `--prune` deletes groups not in the config (phase 0) |
| `test_prune_clears_ghost_id_before_recreate` | `--prune` clears a ghost id from `settings.groups` before re-creating at the same id |
| `test_scene_add_uses_float_transition` | The scene_add JSON encodes `transition` as a float, so z2m routes through `enhancedAdd` (Hue bulbs need this) |
| `test_scene_skip_when_id_and_name_match` | Scenes with matching id+name are not re-issued |
| `test_scene_force_update_reissues` | `--force-update` re-issues even matching scenes |
| `test_scene_create_when_name_differs` | A scene whose name no longer matches is re-created |
| `test_device_option_skipped_when_state_matches` | Per-device options are deduped against retained state |
| `test_device_option_written_when_state_differs` | Mismatched options are written one `/set` per option |
| `test_device_option_written_when_no_retained_state` | First-time provisioning writes unconditionally |
| `test_fetch_groups_retries_until_inventory_available` | `_fetch_with_retry` recovers from early-boot races where z2m hasn't published `bridge/groups` yet |

## Why a fake bridge instead of mocking paho-mqtt

The reconciler's value is in *how it talks to MQTT* — transaction
correlation, retained-state handling, the scene_add float-encoding
quirk, the multi-phase prune logic. Mocking the MQTT client would mock
out exactly the surface area we want to test. The fake bridge is small
(~250 lines in `conftest.py`) and gives us real broker semantics for
QoS, retain flags, and message ordering.

## Adding new tests

1. If the new behavior needs a different bridge response shape, add a
   handler to `FakeZ2m._on_message` in `conftest.py`.
2. Use `fake_z2m.add_existing_group(...)` /
   `fake_z2m.add_ghost_id(...)` / `fake_z2m.seed_device_state(...)` to
   set up the initial inventory.
3. Drive the reconciler through `_reconcile(...)` and assert on
   `fake_z2m.snapshot()`, `fake_z2m.scene_add_raw`, or
   `fake_z2m.device_sets`.
