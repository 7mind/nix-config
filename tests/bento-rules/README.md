# bento-rules tests

Tests for the bento rule patterns used by
`modules/nixos/mqtt-automations.nix` and `private/hosts/raspi5m/hue-lights-tools.nix`.

Two layers:

* **Behavior tests** (`test_bento_rules.py`) — boot a private mosquitto
  broker on an ephemeral port, render a bento config by `nix eval`-ing
  the *real* `modules/nixos/mqtt-automations.nix` renderer against a
  small rules attrset, start bento against the rendered config,
  publish MQTT events, and assert on the responses. Nothing is mocked
  — real bento + real mosquitto + real paho-mqtt + real renderer. Any
  refactor of `mkRuleCase` / `mkActionCases` / processor ordering
  shows up immediately as a behavior change.
* **Renderer tests** (`test_renderer.py`) — shell out to `nix eval
  --impure --json` against `defineRooms` with synthetic room
  definitions and assert on the JSON-decoded attrset (cache labels,
  handler keys, bloblang substrings, validation errors). Catches a
  refactor that changes generated rule shape in a subtly-broken way
  before it ships.

The two layers cover different surfaces: `test_renderer.py` exercises
the room → rules transform (`defineRooms`), and `test_bento_rules.py`
exercises both the rules → bento config transform (`mqtt-automations`)
and the runtime semantics of the resulting bento processors.

## Running

```
cd tests/bento-rules
nix-shell --run 'pytest -n auto'
```

`-n auto` runs the suite under `pytest-xdist`, one worker per core,
which brings the full 32-test run from ~35s sequential to ~4s on a
24-core box. Each test gets its own ephemeral mosquitto + bento
instance so there are no cross-worker collisions.

Single tests (sequential):

```
nix-shell --run 'pytest -v -k debounce'
```

## What's covered

### Behavior (`test_bento_rules.py`)

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
| `test_motion_suppressed_during_off_cooldown` | Motion arriving inside the `last_off_at` window is dropped |
| `test_motion_fires_after_cooldown_expires` | Cooldown is timestamp-based, not a flag — releases on its own |
| `test_motion_cooldown_does_not_block_after_user_on_then_off` | User-driven OFF doesn't write `last_off_at`, so motion can still take over |
| `test_multi_sensor_first_fires_and_second_skipped` | Two sensors share a cache; second sensor sees `lights_state="motion"` and no-ops |
| `test_multi_sensor_lights_stay_on_while_one_active` | Sensor A motion-off is suppressed because sensor B's `motion_*` flag is still set |
| `test_multi_sensor_all_off_turns_lights_off` | Lights only go off after the *last* active sensor reports occupancy=false |
| `test_slot_cycle_day_slot_fires_day_sequence` | Time-of-day slot dispatch picks the day cycle when local hour is inside `[fromHour, toHour)` |
| `test_slot_cycle_night_slot_fires_night_sequence` | Same, for the night slot that wraps midnight |
| `test_slot_cycle_boundary_hour_dispatches_correctly` | The boundary hour belongs to the *next* slot (half-open intervals) |

The slot tests use `tz_for_target_local_hour(h)` from `conftest.py` to
set `TZ=Etc/GMT±N` for the bento subprocess so its `time.Local`
reports the desired hour without waiting for the wall clock. The IANA
zone form is required because Go's `time` package treats POSIX `TZ=UTC-5`
strings as plain UTC.

### Renderer (`test_renderer.py`)

| Test | Property checked |
|---|---|
| `test_switch_only_room_generates_single_rule` | Switch-only room produces exactly `<room>-switch` and no cache label |
| `test_motion_only_room_generates_single_motion_rule` | Motion-only room produces `<room>-motion-<sensor>` with `cacheLabel=room_<room>` |
| `test_switch_plus_motion_share_cache_label` | Switch + motion in same room share one `room_<room>` cache resource |
| `test_motion_on_check_has_luminance_and_lights_state_gates` | `motion-on` check contains occupancy/illuminance/lights_state/cooldown clauses |
| `test_motion_on_check_respects_max_illuminance_override` | Per-room `maxIlluminance` flows into the bloblang threshold |
| `test_luminance_gate_can_be_disabled` | `maxIlluminance = null` strips the illuminance clause entirely |
| `test_multi_sensor_generates_rule_per_sensor` | `motionSensor.names = [...]` produces one rule per sensor, all sharing one cache label |
| `test_multi_sensor_motion_off_checks_other_sensors` | Each sensor's `motion-off` references the *other* sensors' flags but never its own |
| `test_multi_sensor_pre_dispatch_updates_own_flag` | Every motion rule's `preDispatch` writes its own `motion_<self>` regardless of dispatch outcome |
| `test_hue_setup_groups_contain_members_and_scenes` | `hue-setup.config.groups` is populated from `members` and `scenes` |
| `test_hue_setup_devices_emits_motion_sensor_options` | Each motion sensor gets `occupancy_timeout` / `motion_sensitivity` / `led_indication` |
| `test_validation_duplicate_group_id` | Duplicate group ids fail evaluation with `duplicate group id` |
| `test_validation_requires_control_source` | A room with neither `switch` nor `motionSensor` fails with the documented message |
| `test_validation_catches_shared_bulb_scene_conflict` | Two rooms claiming the same bulb with conflicting scene definitions fail with `per-bulb scene conflicts` |

## Bugs caught by this suite

**Debounce was a silent no-op in production.** While writing
`test_debounce_suppresses_rapid_presses`, the test failed because the
debounce mapping in `modules/nixos/mqtt-automations.nix` was using
`root = if ... { deleted() } else { this }`. The `this` reference
errors on plain-text action payloads (e.g. `"on_press_release"`)
because bloblang can't parse them as JSON. The failed assignment left
`root` unchanged, so the subsequent cycle compute always ran. Fixed by
replacing with a top-level `if ($now - $last) < <n> { root = deleted() }`,
which doesn't reference `this` at all.

**Multi-sensor short-circuit lost per-sensor occupancy state.** While
writing `test_multi_sensor_lights_stay_on_while_one_active`, we
discovered that when sensor A fired motion-on first and set
`lights_state="motion"`, sensor B's motion-on was correctly
short-circuited by the `lights_state==""` gate — but its
`motion_<self>` write lived in the handler's `cacheWrites` and so was
also skipped. Later, when sensor A's motion-off fired, it saw a stale
`motion_B=""` and turned the lights off while B was still reporting
occupancy. Fixed by adding a `preDispatch` rule-level option to
`mqtt-automations.nix` and using it from `mkMotionRule` to update
`motion_<self>` *unconditionally* before the dispatch switch runs.

## Adding new tests

### Behavior test

1. Add a config builder function at the top of `test_bento_rules.py`
   that constructs a `rules` attrset (mirroring the
   `smind.services.mqtt-automations.rules` option shape) and passes
   it to `_render_bento_config(rules)`. The renderer takes care of
   substituting `{MQTT_HOST}` / `{MQTT_PORT}` / `{HTTP_PORT}` placeholders.
2. Write a test function taking `bento_runner` and `mqtt_client`
   fixtures.
3. Use `_publish(client, topic, payload)` to send events and
   `inbox.wait_for_count(topic, n)` / `inbox.payloads_on(topic)` to
   assert on the output.
4. Use `inbox.wait_silence(topic, for_s=0.4)` for "no message expected"
   cases.
5. For time-of-day behavior, pass `tz=tz_for_target_local_hour(h)` to
   `bento_runner(...)` so bento's `time.Local` reports the desired hour.

`_render_bento_config` uses `lib.evalModules` against
`modules/nixos/mqtt-automations.nix` (with a stub `systemd` option so
the module's `config` block can apply), reads `renderedConfig`, then
mutates it in Python to enable HTTP for the readiness probe, swap in
the test broker URL, and strip user/password (the test broker is
anonymous). The result is JSON, which bento parses fine since YAML
is a JSON superset.

### Renderer test

1. Add a function in `test_renderer.py` that calls `_eval_define_rooms`
   with a Nix snippet describing one or more rooms.
2. Assert on the JSON-decoded result, e.g.
   `result["smind"]["services"]["mqtt-automations"]["rules"]["..."]`.
3. For expected-failure cases use `_eval_expect_error` and assert on
   the substring of the error message that the validator emits.
