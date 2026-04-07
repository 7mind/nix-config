# bento-rules tests

End-to-end tests for the bento rule patterns used by
`modules/nixos/mqtt-automations.nix` and `private/hosts/raspi5m/hue-lights-tools.nix`.

Each test boots a private mosquitto broker on an ephemeral port, starts
bento against a hand-crafted YAML config that mirrors the output of our
Nix renderer, publishes MQTT events, and asserts on the responses.
Nothing is mocked — the tests run real bento + real mosquitto + real
paho-mqtt.

## Running

```
cd tests/bento-rules
nix-shell --run pytest
```

Or, for verbose output / single tests:

```
nix-shell --run 'pytest -v'
nix-shell --run 'pytest -v -k debounce'
```

## What's covered

| Test | Pattern exercised |
|---|---|
| `test_flat_cycle_advances_and_wraps` | Flat cycle: press N times, assert preset index cycles 0→1→2→0 |
| `test_debounce_suppresses_rapid_presses` | Timestamp-based debounce drops presses within the window |
| `test_debounce_expires_between_presses` | Press spaced > window fires again |
| `test_off_press_resets_cycle` | `resetCycles` on off handler zeros the cycle index and debounce timestamp |
| `test_motion_fires_in_dark_with_lights_off` | Motion with `occupancy=true` + low illuminance + `lights_state=""` publishes scene |
| `test_motion_suppressed_when_bright` | Luminance gate rejects motion above threshold |
| `test_motion_off_turns_off_when_motion_on_ran_earlier` | Full auto cycle: occupancy up → scene, occupancy down → OFF |
| `test_user_press_cancels_motion_off` | User on-press sets `lights_state="user"`, subsequent motion-off doesn't trigger |
| `test_motion_suppressed_when_lights_already_on_manually` | Motion-on no-ops while `lights_state="user"` |

## What's NOT covered (room for follow-up)

- **Time-of-day slots**: `timestamp_unix().ts_format(...)` is runtime-dependent,
  hard to test without time-travel. Possible approach: inject a `let h = N`
  override via meta. Not implemented.
- **Multi-sensor OR semantics**: the test config builder only generates
  single-sensor motion rules. Could be added by generating multiple
  broker inputs plus per-sensor flag tracking.
- **Off cooldown (`last_off_at`)**: same timing-fragile territory; skipped
  for now but the config builder could grow a `cooldown_ms` parameter.
- **Actual Nix renderer output correctness**: these tests verify
  *behavior*, not that `mkSwitchRule` / `mkMotionRule` produce the
  expected YAML structure. A separate pure-Nix golden-file diff would
  cover that.

## Important bug caught by this suite

While writing `test_debounce_suppresses_rapid_presses`, the test failed
because the debounce mapping in `modules/nixos/mqtt-automations.nix`
was using `root = if ... { deleted() } else { this }`. The `this`
reference errors on plain-text action payloads (e.g.
`"on_press_release"`) because bloblang can't parse them as JSON. The
failed assignment left `root` unchanged, so the subsequent cycle
compute always ran and debounce was a silent no-op in production.

Fixed in the same commit that added the tests: replaced with a
top-level `if ($now - $last) < <n> { root = deleted() }`, which
doesn't reference `this` at all.

## Adding new tests

1. Add a config builder function at the top of `test_bento_rules.py`
   (e.g. `_my_new_pattern_config(**params)` returning a YAML string
   with `{MQTT_HOST}` / `{MQTT_PORT}` placeholders).
2. Write a test function taking `bento_runner` and `mqtt_client`
   fixtures.
3. Use `_publish(client, topic, payload)` to send events and
   `inbox.wait_for_count(topic, n)` / `inbox.payloads_on(topic)` to
   assert on the output.
4. Use `inbox.wait_silence(topic, for_s=0.4)` for "no message expected"
   cases.
