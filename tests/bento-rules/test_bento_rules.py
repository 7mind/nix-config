"""End-to-end tests for bento rule patterns.

Each test boots a real mosquitto + bento combination (via fixtures in
conftest.py), hands bento a config that exercises one or more of the
patterns rendered by our Nix helpers, and publishes MQTT events while
asserting on the output topic.

The configs here are hand-crafted but structurally identical to what
`mkSwitchRule` / `mkMotionRule` in hue-lights-tools.nix generate — so
a rule pattern regression in the renderer would still be caught
indirectly if you keep these tests in sync with the helper output.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any

import paho.mqtt.client as mqtt

from conftest import BentoRunner, MqttInbox, tz_for_target_local_hour


SOURCE_TOPIC = "test/switch/action"
MOTION_TOPIC = "test/motion-sensor"
TARGET_TOPIC = "test/group/set"


REPO_ROOT = Path(__file__).resolve().parents[2]
MQTT_AUTOMATIONS_PATH = REPO_ROOT / "modules/nixos/mqtt-automations.nix"


def _render_bento_config(rules: dict[str, Any]) -> str:
    """Render a bento config YAML/JSON string from a rules attrset by
    invoking the *real* `modules/nixos/mqtt-automations.nix` renderer
    via `nix eval`, then post-processing the result for the test
    environment.

    The point of this helper is to keep the behavior tests honest
    against the rendering pipeline: any change to how `mkRuleCase`
    composes processors, where it places `preDispatch`, how it builds
    `cacheReads` branches, etc., is reflected in what the bento
    process actually receives — instead of being shadowed by a
    hand-rolled YAML twin that drifts.

    Test-only mutations applied to the rendered config:
      * `http.enabled = true` with the test fixture's HTTP_PORT
        placeholder (the production module disables HTTP entirely)
      * MQTT URLs replaced with the `{MQTT_HOST}` / `{MQTT_PORT}`
        placeholders that `bento_runner` substitutes
      * `user` / `password` stripped from inputs/outputs because the
        test mosquitto allows anonymous connections

    The returned string is JSON, which bento parses fine since YAML
    is a JSON superset.
    """
    rules_json = json.dumps(rules)
    # Outer json.dumps wraps the inner JSON in a Nix string literal
    # so `builtins.fromJSON` can decode it. JSON and Nix string-literal
    # escaping happen to agree on `\"` and `\\`, so this works as long
    # as we also neutralize Nix antiquotation: any `${` inside the JSON
    # (e.g. bento's `${! timestamp_unix_milli() }` interpolation in a
    # cacheWrites value) would otherwise trigger Nix to try expanding
    # the expression, so we escape it to `\${`. Avoids hand-rolling a
    # Python→Nix value converter for arbitrarily-nested attrsets.
    rules_nix_string = json.dumps(rules_json).replace("${", "\\${")
    expr = f"""
let
  pkgs = import <nixpkgs> {{ }};
  lib = pkgs.lib;
  rules = builtins.fromJSON {rules_nix_string};
  result = lib.evalModules {{
    specialArgs = {{ inherit pkgs; }};
    modules = [
      {MQTT_AUTOMATIONS_PATH}
      ({{ ... }}: {{
        # Stub the systemd option tree so the module's `config` block
        # (which assigns to systemd.services.mqtt-automation) doesn't
        # error during eval. We're only after the renderedConfig
        # value, so the systemd assignment is harmless filler here.
        options.systemd = lib.mkOption {{
          type = lib.types.attrs;
          default = {{ }};
        }};
        config.smind.services.mqtt-automations = {{
          enable = true;
          mqtt = {{
            host = "127.0.0.1";
            port = 1883;
            user = "test";
            passwordFile = "/dev/null";
          }};
          inherit rules;
        }};
      }})
    ];
  }};
in result.config.smind.services.mqtt-automations.renderedConfig
"""
    proc = subprocess.run(
        ["nix", "eval", "--impure", "--json", "--expr", expr],
        capture_output=True,
        text=True,
        env={**os.environ, "NIX_CONFIG": "experimental-features = nix-command flakes"},
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"nix eval failed (exit {proc.returncode}):\n"
            f"--- stderr ---\n{proc.stderr}\n"
            f"--- expr ---\n{expr}"
        )
    rendered: dict[str, Any] = json.loads(proc.stdout)

    # Enable HTTP for the readiness probe
    rendered["http"] = {
        "enabled": True,
        "address": "127.0.0.1:{HTTP_PORT}",
    }

    placeholder_url = "tcp://{MQTT_HOST}:{MQTT_PORT}"

    def _strip_mqtt(spec: dict[str, Any]) -> None:
        spec["urls"] = [placeholder_url]
        spec.pop("user", None)
        spec.pop("password", None)

    # Inputs are wrapped in a broker
    for input_def in rendered["input"]["broker"]["inputs"]:
        _strip_mqtt(input_def["mqtt"])

    _strip_mqtt(rendered["output"]["mqtt"])

    return json.dumps(rendered)


# ---------- config builders ----------


def _flat_cycle_config(*, debounce_ms: int, values: list[dict]) -> str:
    """Bento config for a flat cycle handler.

    Mirrors `mkSwitchRule` with a flat `values = [...]` cycle and the
    given debounce window. Presses on `{SOURCE_TOPIC}`, publishes to
    `{TARGET_TOPIC}`, state in an in-memory cache.

    Rendered through the real `mqtt-automations.nix` renderer so any
    drift in how `mkRuleCase` composes processors fails the test.
    """
    return _render_bento_config({
        "test-cycle": {
            "source": SOURCE_TOPIC,
            "target": TARGET_TOPIC,
            "format": "action",
            "handlers": {
                "on_press_release": {
                    "cycle": {
                        "stateKey": "preset_idx",
                        "values": values,
                        "debounceMs": debounce_ms,
                    },
                },
                "off_press_release": {
                    "publish": {"state": "OFF"},
                    "resetCycles": ["preset_idx"],
                },
            },
        },
    })


def _slot_cycle_config(*, slots: dict[str, dict]) -> str:
    """Bento config for a slot-aware cycle handler, rendered through
    the real `mqtt-automations.nix` renderer.

    `slots` is an attrset-of-dicts that mirrors the production option
    shape: `{ "day": { "fromHour": 6, "toHour": 23, "values": [...] },
    "night": { "fromHour": 23, "toHour": 6, "values": [...] } }`.
    The renderer is responsible for assembling the if/else slot chain
    in bloblang — the test driver only describes intent.
    """
    return _render_bento_config({
        "test-slot-cycle": {
            "source": SOURCE_TOPIC,
            "target": TARGET_TOPIC,
            "format": "action",
            "handlers": {
                "on_press_release": {
                    "cycle": {
                        "stateKey": "preset_idx",
                        "slots": slots,
                    },
                },
            },
        },
    })


def _motion_config(*, max_illuminance: int, cooldown_ms: int = 0) -> str:
    """Bento config for a motion sensor with luminance gate and a
    matching switch with lights_state coordination.

    Subscribes to both the motion sensor's JSON state topic and the
    switch's action topic. Both paths share `cache_resources.state`.

    When `cooldown_ms > 0`, the motion-on check additionally requires
    `(now - last_off_at) >= cooldown_ms`, and the switch off handler
    stamps `last_off_at` with the current epoch-ms via
    `${{! timestamp_unix_milli() }}` interpolation — matching the
    production `mkSwitchRule` / `mkMotionRule` shapes.
    """
    # Both rules share the cache via an explicit cacheLabel — this
    # is exactly how the production `defineRooms` helper coordinates
    # a switch and a motion sensor that target the same room. The
    # production renderer derives the label from the room name; for
    # tests we hardcode "test_room" so both rules below land on the
    # same in-memory resource.
    cache_label = "test_room"

    motion_check = (
        'this.occupancy == true '
        '&& (this.illuminance.or(99999).number()) < ' + str(max_illuminance) + ' '
        '&& (meta("lights_state").or("")) == ""'
    )
    motion_cache_reads = ["lights_state"]
    if cooldown_ms > 0:
        motion_check += (
            ' && (timestamp_unix_milli() - '
            f'(meta("last_off_at").or("0").number().or(0))) >= {cooldown_ms}'
        )
        motion_cache_reads.append("last_off_at")

    # The switch's off handler stamps last_off_at via bento's
    # ${! ... } interpolation. The renderer passes cacheWrites
    # values through unchanged to a cache.set processor.
    switch_off_writes: dict[str, str] = {"lights_state": ""}
    if cooldown_ms > 0:
        switch_off_writes["last_off_at"] = "${! timestamp_unix_milli() }"

    rules = {
        "test-motion": {
            "source": MOTION_TOPIC,
            "target": TARGET_TOPIC,
            "format": "json",
            "cacheLabel": cache_label,
            "cacheReads": motion_cache_reads,
            "handlers": {
                "motion-on": {
                    "check": motion_check,
                    "publish": {"scene_recall": 1},
                    "cacheWrites": {"lights_state": "motion"},
                },
                "motion-off": {
                    "check": (
                        'this.occupancy == false '
                        '&& (meta("lights_state").or("")) == "motion"'
                    ),
                    "publish": {"state": "OFF"},
                    "cacheWrites": {"lights_state": ""},
                },
            },
        },
        "test-switch": {
            "source": SOURCE_TOPIC,
            "target": TARGET_TOPIC,
            "format": "action",
            "cacheLabel": cache_label,
            "handlers": {
                "off_press_release": {
                    "publish": {"state": "OFF"},
                    "cacheWrites": switch_off_writes,
                },
                "on_press_release": {
                    "publish": {"scene_recall": 1},
                    "cacheWrites": {"lights_state": "user"},
                },
                "up_press_release": {
                    "publish": {"brightness_step": 25},
                    "cacheWrites": {"lights_state": "user"},
                },
            },
        },
    }
    return _render_bento_config(rules)


# ---------- helpers ----------


def _subscribe(client: mqtt.Client, topic: str) -> None:
    client.subscribe(topic, qos=1)
    # small beat so the SUBSCRIBE completes before the test publishes
    time.sleep(0.1)


def _publish(client: mqtt.Client, topic: str, payload: str) -> None:
    info = client.publish(topic, payload, qos=1)
    info.wait_for_publish(timeout=2.0)
    assert info.is_published(), f"publish to {topic} did not confirm"


# ---------- cycle tests ----------


def test_flat_cycle_advances_and_wraps(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """On presses walk 0→1→2→0 through a 3-value flat cycle."""
    client, inbox = mqtt_client
    bento_runner(_flat_cycle_config(
        debounce_ms=0,
        values=[{"label": "v0"}, {"label": "v1"}, {"label": "v2"}],
    ))
    _subscribe(client, TARGET_TOPIC)

    for _ in range(4):
        _publish(client, SOURCE_TOPIC, "on_press_release")
        time.sleep(0.15)

    inbox.wait_for_count(TARGET_TOPIC, 4)
    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [
        {"label": "v0"},
        {"label": "v1"},
        {"label": "v2"},
        {"label": "v0"},
    ]


def test_debounce_suppresses_rapid_presses(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """A 600ms debounce should drop presses that arrive within the window."""
    client, inbox = mqtt_client
    bento_runner(_flat_cycle_config(
        debounce_ms=600,
        values=[{"label": "v0"}, {"label": "v1"}, {"label": "v2"}],
    ))
    _subscribe(client, TARGET_TOPIC)

    # 5 presses 100ms apart = 500ms total, all within one debounce window
    for _ in range(5):
        _publish(client, SOURCE_TOPIC, "on_press_release")
        time.sleep(0.1)

    time.sleep(0.3)  # give bento time to finish processing the trailing ones

    # Only the first press should have fired; the rest are debounced
    payloads = inbox.payloads_on(TARGET_TOPIC)
    assert len(payloads) == 1, f"expected 1 fire, got {payloads}"
    assert json.loads(payloads[0]) == {"label": "v0"}


def test_debounce_expires_between_presses(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """After the debounce window passes, the next press should fire."""
    client, inbox = mqtt_client
    bento_runner(_flat_cycle_config(
        debounce_ms=300,
        values=[{"label": "v0"}, {"label": "v1"}, {"label": "v2"}],
    ))
    _subscribe(client, TARGET_TOPIC)

    _publish(client, SOURCE_TOPIC, "on_press_release")
    time.sleep(0.5)  # > debounce window
    _publish(client, SOURCE_TOPIC, "on_press_release")
    time.sleep(0.5)  # > debounce window
    _publish(client, SOURCE_TOPIC, "on_press_release")

    inbox.wait_for_count(TARGET_TOPIC, 3)
    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [
        {"label": "v0"},
        {"label": "v1"},
        {"label": "v2"},
    ]


def test_off_press_resets_cycle(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """OFF between ON presses should restart the cycle from index 0."""
    client, inbox = mqtt_client
    bento_runner(_flat_cycle_config(
        debounce_ms=0,
        values=[{"label": "v0"}, {"label": "v1"}, {"label": "v2"}],
    ))
    _subscribe(client, TARGET_TOPIC)

    # Advance cycle to index 1 (next press would be v1)
    _publish(client, SOURCE_TOPIC, "on_press_release")
    time.sleep(0.15)

    # OFF resets
    _publish(client, SOURCE_TOPIC, "off_press_release")
    time.sleep(0.15)

    # Next ON should be v0 again, not v1
    _publish(client, SOURCE_TOPIC, "on_press_release")

    inbox.wait_for_count(TARGET_TOPIC, 3)
    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [
        {"label": "v0"},
        {"state": "OFF"},
        {"label": "v0"},
    ]


# ---------- motion tests ----------


def test_motion_fires_in_dark_with_lights_off(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """occupancy=true + low lux + lights_state="" → publishes scene_recall."""
    client, inbox = mqtt_client
    bento_runner(_motion_config(max_illuminance=100))
    _subscribe(client, TARGET_TOPIC)

    _publish(client, MOTION_TOPIC, json.dumps({
        "occupancy": True,
        "illuminance": 40,
    }))

    inbox.wait_for_count(TARGET_TOPIC, 1)
    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [{"scene_recall": 1}]


def test_motion_suppressed_when_bright(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """occupancy=true but illuminance above threshold → no publish."""
    client, inbox = mqtt_client
    bento_runner(_motion_config(max_illuminance=100))
    _subscribe(client, TARGET_TOPIC)

    _publish(client, MOTION_TOPIC, json.dumps({
        "occupancy": True,
        "illuminance": 500,  # above threshold
    }))

    inbox.wait_silence(TARGET_TOPIC, for_s=0.6)


def test_motion_off_turns_off_when_motion_on_ran_earlier(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Full motion cycle: on → lights_state="motion", off → lights OFF."""
    client, inbox = mqtt_client
    bento_runner(_motion_config(max_illuminance=100))
    _subscribe(client, TARGET_TOPIC)

    _publish(client, MOTION_TOPIC, json.dumps({
        "occupancy": True, "illuminance": 40,
    }))
    time.sleep(0.2)
    _publish(client, MOTION_TOPIC, json.dumps({
        "occupancy": False,
    }))

    inbox.wait_for_count(TARGET_TOPIC, 2)
    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [
        {"scene_recall": 1},
        {"state": "OFF"},
    ]


def test_user_press_cancels_motion_off(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """If the user takes control (on_press), a subsequent motion-off
    event must NOT turn the lights off — lights_state is "user" and
    the motion-off check fails."""
    client, inbox = mqtt_client
    bento_runner(_motion_config(max_illuminance=100))
    _subscribe(client, TARGET_TOPIC)

    # Motion auto-on
    _publish(client, MOTION_TOPIC, json.dumps({
        "occupancy": True, "illuminance": 40,
    }))
    time.sleep(0.15)

    # User takes over with an explicit on_press
    _publish(client, SOURCE_TOPIC, "on_press_release")
    time.sleep(0.15)

    # Sensor eventually times out. This should NOT turn the lights off.
    _publish(client, MOTION_TOPIC, json.dumps({
        "occupancy": False,
    }))
    time.sleep(0.4)

    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    # Expected: motion-on published scene_recall, user press published
    # scene_recall, motion-off was ignored (no state:OFF).
    assert payloads == [
        {"scene_recall": 1},
        {"scene_recall": 1},
    ]
    assert {"state": "OFF"} not in payloads


def test_motion_suppressed_when_lights_already_on_manually(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """User presses on first → lights_state="user". A later motion
    event with low lux must not re-publish the scene."""
    client, inbox = mqtt_client
    bento_runner(_motion_config(max_illuminance=100))
    _subscribe(client, TARGET_TOPIC)

    _publish(client, SOURCE_TOPIC, "on_press_release")
    time.sleep(0.15)

    _publish(client, MOTION_TOPIC, json.dumps({
        "occupancy": True, "illuminance": 40,
    }))
    time.sleep(0.3)

    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    # Only the user press should have fired.
    assert payloads == [{"scene_recall": 1}]


# ---------- off cooldown tests ----------


def test_motion_suppressed_during_off_cooldown(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """After a manual OFF press, motion within the cooldown window
    must be suppressed even when lux is low and lights_state is
    empty. The switch's off handler stamps `last_off_at` with the
    current epoch-ms; the motion-on check enforces
    `(now - last_off_at) >= cooldown_ms`."""
    client, inbox = mqtt_client
    # 600ms cooldown keeps the test fast
    bento_runner(_motion_config(max_illuminance=100, cooldown_ms=600))
    _subscribe(client, TARGET_TOPIC)

    # User presses off — this stamps last_off_at and clears lights_state
    _publish(client, SOURCE_TOPIC, "off_press_release")
    time.sleep(0.1)

    # Motion event within cooldown — should be suppressed
    _publish(client, MOTION_TOPIC, json.dumps({
        "occupancy": True, "illuminance": 40,
    }))

    inbox.wait_silence(TARGET_TOPIC, for_s=0.4)

    # Only the OFF press itself should be in the output
    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [{"state": "OFF"}]


def test_motion_fires_after_cooldown_expires(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Once the cooldown window has elapsed, motion triggers
    normally again."""
    client, inbox = mqtt_client
    bento_runner(_motion_config(max_illuminance=100, cooldown_ms=400))
    _subscribe(client, TARGET_TOPIC)

    _publish(client, SOURCE_TOPIC, "off_press_release")
    time.sleep(0.5)  # > cooldown

    _publish(client, MOTION_TOPIC, json.dumps({
        "occupancy": True, "illuminance": 40,
    }))

    inbox.wait_for_count(TARGET_TOPIC, 2)
    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [
        {"state": "OFF"},
        {"scene_recall": 1},
    ]


def _multi_motion_config(*, sensor_topics: list[str]) -> str:
    """Bento config for a room with N motion sensors sharing a cache,
    rendered through the real `mqtt-automations.nix` renderer.

    Mirrors `mkMotionRule`'s per-sensor rule generation: each sensor
    becomes its own rule that subscribes to its own topic, shares
    `cacheLabel = "test_room"` with the others, has a `preDispatch`
    that unconditionally updates its `motion_<self>` flag from
    `this.occupancy`, and the motion-off check guards on every
    *other* sensor's flag being inactive.
    """

    # Sanitize a topic into a legal cache key: take the last path
    # segment and replace hyphens with underscores. Has to match how
    # the production renderer derives sensor keys from sensor names.
    def _key(topic: str) -> str:
        leaf = topic.rsplit("/", 1)[-1]
        return leaf.replace("-", "_")

    sensor_keys = {t: _key(t) for t in sensor_topics}
    cache_label = "test_room"

    def _others_inactive_clause(self_topic: str) -> str:
        others = [sensor_keys[t] for t in sensor_topics if t != self_topic]
        return "".join(
            f' && (meta("motion_{k}").or("")) != "1"' for k in others
        )

    def _make_rule(self_topic: str) -> dict[str, Any]:
        self_key = sensor_keys[self_topic]
        # Each sensor reads lights_state plus every *other* sensor's
        # motion flag (but not its own — the preDispatch below sets
        # that flag based on the current message).
        cache_reads = ["lights_state"] + [
            f"motion_{sensor_keys[t]}" for t in sensor_topics if t != self_topic
        ]
        return {
            "source": self_topic,
            "target": TARGET_TOPIC,
            "format": "json",
            "cacheLabel": cache_label,
            "cacheReads": cache_reads,
            "preDispatch": [
                {
                    "mapping": (
                        'meta motion_self_update = '
                        'if this.occupancy { "1" } else { "" }'
                    ),
                },
                {
                    "cache": {
                        "resource": cache_label,
                        "operator": "set",
                        "key": f"motion_{self_key}",
                        "value": '${! meta("motion_self_update") }',
                    },
                },
            ],
            "handlers": {
                "motion-on": {
                    "check": (
                        'this.occupancy == true '
                        '&& (meta("lights_state").or("")) == ""'
                    ),
                    "publish": {"scene_recall": 1},
                    "cacheWrites": {"lights_state": "motion"},
                },
                "motion-off": {
                    "check": (
                        'this.occupancy == false '
                        '&& (meta("lights_state").or("")) == "motion"'
                        + _others_inactive_clause(self_topic)
                    ),
                    "publish": {"state": "OFF"},
                    "cacheWrites": {"lights_state": ""},
                },
            },
        }

    rules = {
        f"sensor-{sensor_keys[t]}": _make_rule(t) for t in sensor_topics
    }
    return _render_bento_config(rules)


# ---------- multi-sensor OR-semantics tests ----------


SENSOR_A = "test/motion-a"
SENSOR_B = "test/motion-b"


def test_multi_sensor_first_fires_and_second_skipped(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Two sensors in one room. Sensor A fires occupancy=true → lights on,
    lights_state="motion". Sensor B then fires occupancy=true → nothing,
    because lights_state != "" blocks the motion-on check."""
    client, inbox = mqtt_client
    bento_runner(_multi_motion_config(sensor_topics=[SENSOR_A, SENSOR_B]))
    _subscribe(client, TARGET_TOPIC)

    _publish(client, SENSOR_A, json.dumps({"occupancy": True}))
    time.sleep(0.15)
    _publish(client, SENSOR_B, json.dumps({"occupancy": True}))
    time.sleep(0.2)

    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [{"scene_recall": 1}]


def test_multi_sensor_lights_stay_on_while_one_active(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Sensor A fires on, sensor B fires on (no-op), sensor A fires off.
    Because sensor B is still flagged active, motion-off from A should
    NOT turn lights off — the "others inactive" guard fails."""
    client, inbox = mqtt_client
    bento_runner(_multi_motion_config(sensor_topics=[SENSOR_A, SENSOR_B]))
    _subscribe(client, TARGET_TOPIC)

    # A on → scene
    _publish(client, SENSOR_A, json.dumps({"occupancy": True}))
    time.sleep(0.15)
    # B on → no-op (lights_state already "motion")
    _publish(client, SENSOR_B, json.dumps({"occupancy": True}))
    time.sleep(0.15)
    # A off → should NOT turn off (B still flagged active)
    _publish(client, SENSOR_A, json.dumps({"occupancy": False}))

    inbox.wait_silence(TARGET_TOPIC, for_s=0.4)

    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [{"scene_recall": 1}], (
        f"expected lights to stay on while sensor B still active, "
        f"but got extra messages: {payloads}"
    )


def test_multi_sensor_all_off_turns_lights_off(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Both sensors fire on, then both fire off. Lights should turn
    off only after the *last* sensor has also reported no motion."""
    client, inbox = mqtt_client
    bento_runner(_multi_motion_config(sensor_topics=[SENSOR_A, SENSOR_B]))
    _subscribe(client, TARGET_TOPIC)

    _publish(client, SENSOR_A, json.dumps({"occupancy": True}))
    time.sleep(0.1)
    _publish(client, SENSOR_B, json.dumps({"occupancy": True}))
    time.sleep(0.1)
    # First off — should NOT turn off (other still active)
    _publish(client, SENSOR_A, json.dumps({"occupancy": False}))
    time.sleep(0.15)
    # Second off — NOW both are inactive, should turn off
    _publish(client, SENSOR_B, json.dumps({"occupancy": False}))

    inbox.wait_for_count(TARGET_TOPIC, 2)
    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [
        {"scene_recall": 1},   # A on
        {"state": "OFF"},       # B off (last to go inactive)
    ]


# ---------- time-of-day slot tests ----------

# A two-slot config: day 06:00–22:59 plays v0/v1/v2; night 23:00–05:59
# plays the same values in reverse order. Tests TZ-inject bento with
# a specific local hour and then assert on which slot's sequence fires.
DAY_NIGHT_SLOTS = {
    "day": {
        "fromHour": 6,
        "toHour": 23,
        "values": [
            {"label": "day-v0"},
            {"label": "day-v1"},
            {"label": "day-v2"},
        ],
    },
    "night": {
        "fromHour": 23,
        "toHour": 6,
        "values": [
            {"label": "night-v0"},
            {"label": "night-v1"},
        ],
    },
}


def test_slot_cycle_day_slot_fires_day_sequence(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """TZ-inject bento so local time is 10:00 (well inside day slot),
    then verify presses walk the day sequence."""
    client, inbox = mqtt_client
    bento_runner(
        _slot_cycle_config(slots=DAY_NIGHT_SLOTS),
        tz=tz_for_target_local_hour(10),
    )
    _subscribe(client, TARGET_TOPIC)

    for _ in range(4):
        _publish(client, SOURCE_TOPIC, "on_press_release")
        time.sleep(0.15)

    inbox.wait_for_count(TARGET_TOPIC, 4)
    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [
        {"label": "day-v0"},
        {"label": "day-v1"},
        {"label": "day-v2"},
        {"label": "day-v0"},  # wraps at 3
    ]


def test_slot_cycle_night_slot_fires_night_sequence(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """TZ-inject bento so local time is 02:00 (night slot via
    wrap-around). Presses walk the night sequence, which only has
    two values, so the cycle wraps at 2."""
    client, inbox = mqtt_client
    bento_runner(
        _slot_cycle_config(slots=DAY_NIGHT_SLOTS),
        tz=tz_for_target_local_hour(2),
    )
    _subscribe(client, TARGET_TOPIC)

    for _ in range(3):
        _publish(client, SOURCE_TOPIC, "on_press_release")
        time.sleep(0.15)

    inbox.wait_for_count(TARGET_TOPIC, 3)
    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [
        {"label": "night-v0"},
        {"label": "night-v1"},
        {"label": "night-v0"},  # wraps at 2
    ]


def test_slot_cycle_boundary_hour_dispatches_correctly(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Exactly at 23:00: day slot's `fromHour=6, toHour=23` is
    exclusive on toHour, so hour 23 belongs to the night slot
    (fromHour=23 wraps). Expect night-v0 on first press."""
    client, inbox = mqtt_client
    bento_runner(
        _slot_cycle_config(slots=DAY_NIGHT_SLOTS),
        tz=tz_for_target_local_hour(23),
    )
    _subscribe(client, TARGET_TOPIC)

    _publish(client, SOURCE_TOPIC, "on_press_release")

    inbox.wait_for_count(TARGET_TOPIC, 1)
    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [{"label": "night-v0"}]


def test_motion_cooldown_does_not_block_after_user_on_then_off(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Edge case: user presses on (lights_state=user), then presses
    off (clears flag, stamps cooldown). After the cooldown elapses,
    motion should fire normally."""
    client, inbox = mqtt_client
    bento_runner(_motion_config(max_illuminance=100, cooldown_ms=300))
    _subscribe(client, TARGET_TOPIC)

    _publish(client, SOURCE_TOPIC, "on_press_release")
    time.sleep(0.1)
    _publish(client, SOURCE_TOPIC, "off_press_release")
    time.sleep(0.1)

    # Still within cooldown — should be suppressed
    _publish(client, MOTION_TOPIC, json.dumps({
        "occupancy": True, "illuminance": 40,
    }))
    time.sleep(0.2)
    count_after_first_motion = len(inbox.payloads_on(TARGET_TOPIC))

    # After the cooldown, motion should work
    time.sleep(0.3)  # total elapsed > 300ms since off
    _publish(client, MOTION_TOPIC, json.dumps({
        "occupancy": True, "illuminance": 40,
    }))

    inbox.wait_for_count(TARGET_TOPIC, count_after_first_motion + 1)
    payloads = [json.loads(p) for p in inbox.payloads_on(TARGET_TOPIC)]
    assert payloads == [
        {"scene_recall": 1},  # initial on_press_release
        {"state": "OFF"},      # off_press_release
        {"scene_recall": 1},   # motion after cooldown expired
    ]


# ---------- tap toggle tests (per-binding rules with sourceFilter) ----------


TAP_SOURCE = "test/tap/action"
TAP_TARGET_A = "test/room-a/set"
TAP_TARGET_B = "test/room-b/set"


def _tap_per_binding_config() -> str:
    """Bento config for two per-binding tap rules sharing a source
    topic via disjoint `sourceFilter` checks.

    Mirrors the production `mkTapButtonRule` shape: each rule has
    its own `cacheLabel = room_<roomName>`, `sourceFilter` gating
    the outer dispatch on `(topic, content)`, and a simple `on`/`off`
    handler pair against the room's `lights_state` flag.

    The point of this test is to verify that:
      * bento accepts the `sourceFilter` override (top-level switch
        case check is the user-supplied expression instead of a plain
        topic equality)
      * two rules sharing one MQTT source don't collide — bento
        dispatches each press to exactly one rule based on the
        action content
      * the cache-based toggle alternates correctly per room
      * different rooms have completely independent state (separate
        `room_<name>` cache resources)
      * the input dedup (one MQTT subscription per unique source)
        doesn't cause messages to be dropped
    """
    def per_binding_rule(button: int, room_label: str, target: str) -> dict:
        return {
            "source": TAP_SOURCE,
            "sourceFilter": (
                f'meta("mqtt_topic") == "{TAP_SOURCE}"'
                f' && content().string() == "press_{button}"'
            ),
            "target": target,
            "format": "action",
            "cacheLabel": f"room_{room_label}",
            "cacheReads": ["lights_state"],
            "handlers": {
                "on": {
                    "check": '(meta("lights_state").or("")) == ""',
                    "publish": {"scene_recall": 1},
                    "cacheWrites": {"lights_state": "user"},
                },
                "off": {
                    "check": '(meta("lights_state").or("")) != ""',
                    "publish": {"state": "OFF"},
                    "cacheWrites": {"lights_state": ""},
                },
            },
        }

    rules = {
        "binding-room-a-1": per_binding_rule(1, "a", TAP_TARGET_A),
        "binding-room-b-2": per_binding_rule(2, "b", TAP_TARGET_B),
    }
    return _render_bento_config(rules)


def test_tap_button_toggles_room_on_then_off(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """First press of button 1 turns room A on (scene_recall:1).
    Second press of the same button turns room A off (state:OFF).
    Verifies the per-binding rule + sourceFilter dispatch + cache
    toggle work end-to-end through bento + mosquitto."""
    client, inbox = mqtt_client
    bento_runner(_tap_per_binding_config())
    _subscribe(client, TAP_TARGET_A)

    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.15)
    _publish(client, TAP_SOURCE, "press_1")

    inbox.wait_for_count(TAP_TARGET_A, 2)
    payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert payloads == [
        {"scene_recall": 1},
        {"state": "OFF"},
    ]


def test_tap_buttons_target_different_rooms_independently(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Button 1 → room A, button 2 → room B. Each room has its OWN
    cache resource (`room_a`, `room_b`), so pressing one button
    cannot affect the other room's state — and bento's outer switch
    routes each press to exactly one binding rule based on the
    sourceFilter content match."""
    client, inbox = mqtt_client
    bento_runner(_tap_per_binding_config())
    _subscribe(client, TAP_TARGET_A)
    _subscribe(client, TAP_TARGET_B)

    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.15)
    _publish(client, TAP_SOURCE, "press_2")

    inbox.wait_for_count(TAP_TARGET_A, 1)
    inbox.wait_for_count(TAP_TARGET_B, 1)
    assert [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)] == [
        {"scene_recall": 1}
    ]
    assert [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_B)] == [
        {"scene_recall": 1}
    ]


def test_tap_button_off_press_then_on_press_works(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Sequence: on, off, on, off. Each press must alternate the
    room state correctly. Catches a class of state-machine bugs
    where the off path forgets to clear its flag."""
    client, inbox = mqtt_client
    bento_runner(_tap_per_binding_config())
    _subscribe(client, TAP_TARGET_A)

    for _ in range(4):
        _publish(client, TAP_SOURCE, "press_1")
        time.sleep(0.15)

    inbox.wait_for_count(TAP_TARGET_A, 4)
    payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert payloads == [
        {"scene_recall": 1},
        {"state": "OFF"},
        {"scene_recall": 1},
        {"state": "OFF"},
    ]


def test_tap_button_coordinates_with_motion_via_room_cache(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """The whole point of switching to per-binding tap rules: the
    tap and a motion sensor in the same room share the room's
    `lights_state` flag. After the user presses the tap to turn
    lights on, a subsequent motion-off MUST NOT turn the lights
    off — `lights_state == "user"` blocks it.

    Pre-Option-B (when tap state lived in a tap-private cache),
    this scenario silently failed: the motion sensor saw a stale
    `lights_state == ""` and fired its OFF path."""
    client, inbox = mqtt_client

    # Tap rule (binding-room-a-1) AND a motion rule for the same room.
    # Both use cacheLabel = "room_a" so they share lights_state.
    cache_label = "room_a"
    motion_topic = "test/motion-sensor"
    rules = {
        "tap-binding": {
            "source": TAP_SOURCE,
            "sourceFilter": (
                f'meta("mqtt_topic") == "{TAP_SOURCE}"'
                ' && content().string() == "press_1"'
            ),
            "target": TAP_TARGET_A,
            "format": "action",
            "cacheLabel": cache_label,
            "cacheReads": ["lights_state"],
            "handlers": {
                "on": {
                    "check": '(meta("lights_state").or("")) == ""',
                    "publish": {"scene_recall": 1},
                    "cacheWrites": {"lights_state": "user"},
                },
                "off": {
                    "check": '(meta("lights_state").or("")) != ""',
                    "publish": {"state": "OFF"},
                    "cacheWrites": {"lights_state": ""},
                },
            },
        },
        "motion": {
            "source": motion_topic,
            "target": TAP_TARGET_A,
            "format": "json",
            "cacheLabel": cache_label,
            "cacheReads": ["lights_state"],
            "handlers": {
                "motion-on": {
                    "check": (
                        'this.occupancy == true '
                        '&& (meta("lights_state").or("")) == ""'
                    ),
                    "publish": {"scene_recall": 1},
                    "cacheWrites": {"lights_state": "motion"},
                },
                "motion-off": {
                    "check": (
                        'this.occupancy == false '
                        '&& (meta("lights_state").or("")) == "motion"'
                    ),
                    "publish": {"state": "OFF"},
                    "cacheWrites": {"lights_state": ""},
                },
            },
        },
    }
    bento_runner(_render_bento_config(rules))
    _subscribe(client, TAP_TARGET_A)

    # User presses tap → lights_state becomes "user"
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.2)
    # Motion sensor reports occupancy=false → would normally turn off
    # if lights_state were "motion", but the user owns the lights now.
    _publish(client, motion_topic, json.dumps({"occupancy": False}))
    time.sleep(0.2)

    payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert payloads == [
        {"scene_recall": 1},  # tap on press only
        # NO state:OFF — the motion-off check failed because
        # lights_state == "user", not "motion"
    ], f"motion-off should have been suppressed but got {payloads}"


def test_input_dedup_collapses_shared_source_topic_to_one_subscription() -> None:
    """Two rules with the same `source` topic must produce exactly
    one MQTT input subscription, not two — otherwise mosquitto
    delivers each message twice and the pipeline does N-1 wasted
    dispatch passes per press.

    This is the input-dedup that lets per-binding tap rules share
    one tap source topic without N-fold message amplification."""
    rules = {
        "binding-1": {
            "source": "zigbee2mqtt/tap/action",
            "sourceFilter": (
                'meta("mqtt_topic") == "zigbee2mqtt/tap/action"'
                ' && content().string() == "press_1"'
            ),
            "target": "test/room-a/set",
            "format": "action",
            "handlers": {
                "fire": {
                    "check": "true",
                    "publish": {"scene_recall": 1},
                },
            },
        },
        "binding-2": {
            "source": "zigbee2mqtt/tap/action",
            "sourceFilter": (
                'meta("mqtt_topic") == "zigbee2mqtt/tap/action"'
                ' && content().string() == "press_2"'
            ),
            "target": "test/room-b/set",
            "format": "action",
            "handlers": {
                "fire": {
                    "check": "true",
                    "publish": {"scene_recall": 1},
                },
            },
        },
    }
    rendered = json.loads(_render_bento_config(rules))
    inputs = rendered["input"]["broker"]["inputs"]
    assert len(inputs) == 1, (
        f"expected exactly one input for two rules sharing a source, "
        f"got {len(inputs)}: {inputs}"
    )
    assert inputs[0]["mqtt"]["topics"] == ["zigbee2mqtt/tap/action"]


# ---------- tap cycle behavior (the new mkTapButtonRule pattern) ----------


def _tap_cycle_config(*, cycle_pause_ms: int = 1000) -> str:
    """Bento config matching the production `mkTapButtonRule`'s
    three-handler shape (lights_off / cycle_press / expire_press),
    with static `cacheWrites` per handler.

    Hardcoded scene id list `[1, 2, 3]` mirrors what the production
    renderer would emit for a flat-scenes room with three scenes."""
    delta_expr = (
        '(timestamp_unix_milli() - '
        'meta("tap_last_press_ms").or("0").number().or(0))'
    )
    lights_on_pred = '(meta("lights_state").or("")) != ""'

    # Cycle-advance bloblang: read cur_idx, compute next, stash in
    # meta for the cacheWrite to interpolate.
    advance_mapping = (
        'let scene_ids = [1, 2, 3]\n'
        'let n = $scene_ids.length()\n'
        'let cur_idx = (meta("tap_cycle_idx").or("0").number().or(0))\n'
        'let next_idx = ($cur_idx + 1) % $n\n'
        'meta tap_cycle_idx_next = $next_idx.string()\n'
        'root = {"scene_recall": $scene_ids.index($next_idx)}\n'
    )

    rules = {
        "tap-cycle": {
            "source": TAP_SOURCE,
            "sourceFilter": (
                f'meta("mqtt_topic") == "{TAP_SOURCE}"'
                ' && content().string() == "press_1"'
            ),
            "target": TAP_TARGET_A,
            "format": "action",
            "cacheLabel": "room_a",
            "cacheReads": [
                "lights_state", "tap_cycle_idx", "tap_last_press_ms",
            ],
            "handlers": {
                "lights_off_press": {
                    "check": '(meta("lights_state").or("")) == ""',
                    # First scene = scene_recall: 1
                    "publish": {"scene_recall": 1},
                    "cacheWrites": {
                        "lights_state": "user",
                        "tap_cycle_idx": "0",
                        "tap_last_press_ms": '${! timestamp_unix_milli() }',
                    },
                },
                "cycle_press": {
                    "check": (
                        f'{lights_on_pred} && {delta_expr} < {cycle_pause_ms}'
                    ),
                    "publishMapping": advance_mapping,
                    "cacheWrites": {
                        "lights_state": "user",
                        "tap_cycle_idx": '${! meta("tap_cycle_idx_next") }',
                        "tap_last_press_ms": '${! timestamp_unix_milli() }',
                    },
                },
                "expire_press": {
                    "check": (
                        f'{lights_on_pred} && {delta_expr} >= {cycle_pause_ms}'
                    ),
                    "publish": {"state": "OFF", "transition": 0.8},
                    "cacheWrites": {
                        "lights_state": "",
                        "tap_cycle_idx": "0",
                        "tap_last_press_ms": '${! timestamp_unix_milli() }',
                    },
                },
            },
        },
    }
    return _render_bento_config(rules)


def test_tap_cycle_first_press_turns_on_with_first_scene(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Lights off + press → first scene of the active list."""
    client, inbox = mqtt_client
    bento_runner(_tap_cycle_config())
    _subscribe(client, TAP_TARGET_A)

    _publish(client, TAP_SOURCE, "press_1")

    inbox.wait_for_count(TAP_TARGET_A, 1)
    payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert payloads == [{"scene_recall": 1}]


def test_tap_cycle_advances_within_pause_window(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Three rapid presses (each within the pause window) walk
    through scene 1 → scene 2 → scene 3."""
    client, inbox = mqtt_client
    bento_runner(_tap_cycle_config(cycle_pause_ms=1000))
    _subscribe(client, TAP_TARGET_A)

    for _ in range(3):
        _publish(client, TAP_SOURCE, "press_1")
        time.sleep(0.15)  # well under the 1s pause window

    inbox.wait_for_count(TAP_TARGET_A, 3)
    payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert payloads == [
        {"scene_recall": 1},
        {"scene_recall": 2},
        {"scene_recall": 3},
    ]


def test_tap_cycle_wraps_around_after_last_scene(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Pressing past the last scene wraps back to the first
    (modulo cycle), as long as the pause window keeps holding."""
    client, inbox = mqtt_client
    bento_runner(_tap_cycle_config(cycle_pause_ms=1000))
    _subscribe(client, TAP_TARGET_A)

    for _ in range(4):
        _publish(client, TAP_SOURCE, "press_1")
        time.sleep(0.15)

    inbox.wait_for_count(TAP_TARGET_A, 4)
    payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert payloads == [
        {"scene_recall": 1},
        {"scene_recall": 2},
        {"scene_recall": 3},
        {"scene_recall": 1},  # wraparound
    ]


def test_tap_cycle_press_after_pause_turns_off(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """The user's exact request: lights on, press 1 → first scene,
    press 2 within 1s → second scene, press 3 after 1s → off."""
    client, inbox = mqtt_client
    # Use a short pause so the test runs fast — 300ms threshold.
    bento_runner(_tap_cycle_config(cycle_pause_ms=300))
    _subscribe(client, TAP_TARGET_A)

    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.1)  # within the 300ms window
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.5)  # well past the 300ms window
    _publish(client, TAP_SOURCE, "press_1")

    inbox.wait_for_count(TAP_TARGET_A, 3)
    payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert payloads == [
        {"scene_recall": 1},
        {"scene_recall": 2},
        {"state": "OFF", "transition": 0.8},
    ]


def test_tap_cycle_after_off_starts_fresh_from_first_scene(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """After the cycle has reached the OFF state, the next press
    starts a new cycle from scene 1 — the cycle index gets reset
    on the OFF transition."""
    client, inbox = mqtt_client
    bento_runner(_tap_cycle_config(cycle_pause_ms=300))
    _subscribe(client, TAP_TARGET_A)

    # First press → on (scene 1)
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.1)
    # Within window → advance (scene 2)
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.5)  # past window
    # After window → off
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.1)
    # Press after off → fresh cycle, scene 1 again
    _publish(client, TAP_SOURCE, "press_1")

    inbox.wait_for_count(TAP_TARGET_A, 4)
    payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert payloads == [
        {"scene_recall": 1},
        {"scene_recall": 2},
        {"state": "OFF", "transition": 0.8},
        {"scene_recall": 1},  # cycle reset
    ]


# ---------- parent/child invalidation (cross-room) ----------


def _tap_parent_child_config() -> str:
    """Two per-binding tap rules sharing one source topic, with
    parent → child invalidation that mirrors the production
    `mkTapButtonRule` shape after the kitchen-all → kitchen-cooker
    fix:

      * `child` rule: cacheLabel = "room_child", standard 3-handler
        state machine, no `extraCacheWrites`.
      * `parent` rule: cacheLabel = "room_parent", standard 3-handler
        state machine. The on/cycle handlers ALSO write
        `lights_state = "user"` and `tap_last_press_ms = "0"` to
        "room_child" (descendant is now physically on, force its
        next press into the toggle-off branch). The expire handler
        writes `lights_state = ""` and `tap_last_press_ms = "0"`
        (descendant is now physically off, fresh-on path).
    """
    delta_expr = (
        '(timestamp_unix_milli() - '
        'meta("tap_last_press_ms").or("0").number().or(0))'
    )
    lights_on_pred = '(meta("lights_state").or("")) != ""'
    advance_mapping = (
        'let scene_ids = [1, 2, 3]\n'
        'let n = $scene_ids.length()\n'
        'let cur_idx = (meta("tap_cycle_idx").or("0").number().or(0))\n'
        'let next_idx = ($cur_idx + 1) % $n\n'
        'meta tap_cycle_idx_next = $next_idx.string()\n'
        'root = {"scene_recall": $scene_ids.index($next_idx)}\n'
    )

    def make_handlers(on_extras, off_extras):
        return {
            "lights_off_press": {
                "check": '(meta("lights_state").or("")) == ""',
                "publish": {"scene_recall": 1},
                "cacheWrites": {
                    "lights_state": "user",
                    "tap_cycle_idx": "0",
                    "tap_last_press_ms": '${! timestamp_unix_milli() }',
                },
                "extraCacheWrites": on_extras,
            },
            "cycle_press": {
                "check": f'{lights_on_pred} && {delta_expr} < 1000',
                "publishMapping": advance_mapping,
                "cacheWrites": {
                    "lights_state": "user",
                    "tap_cycle_idx": '${! meta("tap_cycle_idx_next") }',
                    "tap_last_press_ms": '${! timestamp_unix_milli() }',
                },
                "extraCacheWrites": on_extras,
            },
            "expire_press": {
                "check": f'{lights_on_pred} && {delta_expr} >= 1000',
                "publish": {"state": "OFF"},
                "cacheWrites": {
                    "lights_state": "",
                    "tap_cycle_idx": "0",
                    "tap_last_press_ms": '${! timestamp_unix_milli() }',
                },
                "extraCacheWrites": off_extras,
            },
        }

    parent_on_invalidation_to_child = [
        {"resource": "room_child", "key": "lights_state", "value": "user"},
        {"resource": "room_child", "key": "tap_last_press_ms", "value": "0"},
    ]
    parent_off_invalidation_to_child = [
        {"resource": "room_child", "key": "lights_state", "value": ""},
        {"resource": "room_child", "key": "tap_last_press_ms", "value": "0"},
    ]

    rules = {
        "child-binding": {
            "source": TAP_SOURCE,
            "sourceFilter": (
                f'meta("mqtt_topic") == "{TAP_SOURCE}"'
                ' && content().string() == "press_2"'
            ),
            "target": TAP_TARGET_A,
            "format": "action",
            "cacheLabel": "room_child",
            "cacheReads": [
                "lights_state", "tap_cycle_idx", "tap_last_press_ms",
            ],
            "handlers": make_handlers([], []),
        },
        "parent-binding": {
            "source": TAP_SOURCE,
            "sourceFilter": (
                f'meta("mqtt_topic") == "{TAP_SOURCE}"'
                ' && content().string() == "press_1"'
            ),
            "target": TAP_TARGET_B,
            "format": "action",
            "cacheLabel": "room_parent",
            "cacheReads": [
                "lights_state", "tap_cycle_idx", "tap_last_press_ms",
            ],
            "handlers": make_handlers(
                parent_on_invalidation_to_child,
                parent_off_invalidation_to_child,
            ),
        },
    }
    return _render_bento_config(rules)


def test_parent_press_clears_child_state_no_double_press(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """The original user-reported bug: child→parent→parent_off→child
    should NOT require two presses on the child to turn it back on.
    Without parent→child invalidation, the child's stale
    `lights_state="user"` from step 1 plus the timestamp would route
    the next child press into the expire path (off) instead of the
    lights_off path (on).

    Trace with the new (on/off-aware) invalidation:
      1. press child → child.lights_state="user"
      2. press parent → parent on. Parent's on-invalidation writes
         child.lights_state="user" (still on, because it physically is).
      3. wait 1.5s, press parent → parent off (expire). Parent's
         off-invalidation writes child.lights_state="" (now off).
      4. press child → child.lights_state="" → lights_off_press →
         child on with scene 1 on the FIRST press."""
    client, inbox = mqtt_client
    bento_runner(_tap_parent_child_config())
    _subscribe(client, TAP_TARGET_A)  # child target
    _subscribe(client, TAP_TARGET_B)  # parent target

    # 1. Press child (button 2) → child on, scene 1
    _publish(client, TAP_SOURCE, "press_2")
    time.sleep(0.15)

    # 2. Press parent (button 1) → parent on, scene 1.
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(1.5)  # > cyclePauseMs so the next parent press is "expire"

    # 3. Press parent (button 1) → parent off (expire path).
    #    Parent's expire handler clears child's lights_state to "".
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.15)

    # 4. Press child (button 2) → child should turn ON (scene 1)
    #    on the FIRST press, not the second.
    _publish(client, TAP_SOURCE, "press_2")
    time.sleep(0.15)

    # Child target receives exactly two messages: scene 1 (step 1)
    # and scene 1 again (step 4 — fresh on, not OFF).
    child_payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert child_payloads == [
        {"scene_recall": 1},  # step 1
        {"scene_recall": 1},  # step 4 — KEY ASSERTION: not {"state": "OFF"}
    ], (
        f"child press after parent OFF should turn ON immediately, "
        f"not require two presses. got: {child_payloads}"
    )

    # Parent target sees: on (step 2) + off (step 3).
    parent_payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_B)]
    assert parent_payloads == [
        {"scene_recall": 1},  # step 2
        {"state": "OFF"},     # step 3
    ]


def test_parent_on_then_child_press_toggles_child_off_immediate(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """User-reported bug round 2 (kitchen-all → kitchen-cooker):
    after pressing the parent button to turn the whole zone on,
    pressing a child button should toggle the child's sub-zone OFF
    on the FIRST press — because the child's bulbs are physically
    on (lit by the parent press), so the child button's job is to
    toggle them off.

    Trace:
      1. press parent → parent on. ON-invalidation writes
         child.lights_state="user", child.tap_last_press_ms="0".
      2. press child IMMEDIATELY (well within cyclePauseMs from the
         parent's last press, but child has its OWN tap_last_press_ms
         which was just reset to 0 → delta is huge → expire path).
         Child's lights_state="user" + huge delta → expire_press →
         publishes state OFF.

    Without the fix, child.lights_state would have been cleared to
    "" by the parent's invalidation, so the child press would route
    to lights_off_press and emit scene_recall:1 — visually a no-op
    (lights stay on) instead of the user-expected toggle off."""
    client, inbox = mqtt_client
    bento_runner(_tap_parent_child_config())
    _subscribe(client, TAP_TARGET_A)  # child target
    _subscribe(client, TAP_TARGET_B)  # parent target

    # 1. Press parent (button 1) → parent on.
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.15)

    # 2. Press child (button 2) IMMEDIATELY → child should turn OFF.
    _publish(client, TAP_SOURCE, "press_2")
    time.sleep(0.15)

    child_payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert child_payloads == [{"state": "OFF"}], (
        f"child press right after parent on should toggle child OFF, "
        f"not turn it on again. got: {child_payloads}"
    )

    parent_payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_B)]
    assert parent_payloads == [{"scene_recall": 1}]


def test_parent_on_then_delayed_child_press_toggles_child_off(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Same as the previous test but with a delay between the parent
    and child press. The child must still toggle off, regardless of
    timing — the requirement is "each button works with its zone
    regardless of parent/sibling state". Verifies the fix doesn't
    rely on a specific timing window."""
    client, inbox = mqtt_client
    bento_runner(_tap_parent_child_config())
    _subscribe(client, TAP_TARGET_A)
    _subscribe(client, TAP_TARGET_B)

    # 1. Press parent → parent on.
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(1.5)  # well past cyclePauseMs

    # 2. Press child after a delay → child should turn OFF.
    _publish(client, TAP_SOURCE, "press_2")
    time.sleep(0.15)

    child_payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert child_payloads == [{"state": "OFF"}], (
        f"delayed child press after parent on should toggle child OFF. "
        f"got: {child_payloads}"
    )


def test_parent_on_then_child_off_then_child_on_fresh_cycle(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """After parent on → child off (which is the bug fix scenario),
    pressing the child AGAIN should turn it back on (lights_off_press
    path), because the previous expire_press cleared
    child.lights_state to "". Verifies the toggle is fully reversible
    and the child returns to a normal "fresh-on" state machine."""
    client, inbox = mqtt_client
    bento_runner(_tap_parent_child_config())
    _subscribe(client, TAP_TARGET_A)
    _subscribe(client, TAP_TARGET_B)

    # 1. Press parent → parent on, child marked physically on.
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.15)

    # 2. Press child → child off (the bug scenario, now fixed).
    _publish(client, TAP_SOURCE, "press_2")
    time.sleep(0.15)

    # 3. Press child again → child on (fresh, scene 1).
    _publish(client, TAP_SOURCE, "press_2")
    time.sleep(0.15)

    child_payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert child_payloads == [
        {"state": "OFF"},     # step 2 — toggle off (the fix)
        {"scene_recall": 1},  # step 3 — fresh on, child fully reset
    ], (
        f"child should toggle off then back on cleanly. got: {child_payloads}"
    )


def test_child_press_does_not_alter_parent_state(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """The inverse direction: pressing a child must NOT modify the
    parent's cache. The parent's button should still operate
    independently. Verifies the requirement: "each button works with
    its zone regardless of parent/sibling state" — including the
    direction where the child fires first.

    Trace:
      1. press child → child.lights_state="user". Parent untouched.
      2. press parent → parent.lights_state="" → lights_off_press →
         scene_recall:1 (parent on, regardless of whether the child's
         lights are also on)."""
    client, inbox = mqtt_client
    bento_runner(_tap_parent_child_config())
    _subscribe(client, TAP_TARGET_A)
    _subscribe(client, TAP_TARGET_B)

    # 1. Press child (button 2) → child on.
    _publish(client, TAP_SOURCE, "press_2")
    time.sleep(0.15)

    # 2. Press parent (button 1) → parent on, fresh start.
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.15)

    parent_payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_B)]
    assert parent_payloads == [{"scene_recall": 1}], (
        f"parent press after a child press should ignore the child's "
        f"state and turn the parent zone on. got: {parent_payloads}"
    )

    child_payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert child_payloads == [{"scene_recall": 1}]


def test_parent_cycle_keeps_child_in_toggle_off_state(
    bento_runner: BentoRunner,
    mqtt_client: tuple[mqtt.Client, MqttInbox],
) -> None:
    """Cycling the parent (multiple presses within the cycle window)
    must NOT lose the descendant invalidation — every cycle press
    re-applies the on-invalidation, so the child's next press still
    toggles off. Catches a regression where cycle_press has weaker
    invalidation than lights_off_press."""
    client, inbox = mqtt_client
    bento_runner(_tap_parent_child_config())
    _subscribe(client, TAP_TARGET_A)
    _subscribe(client, TAP_TARGET_B)

    # 1. Press parent → first scene
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.15)
    # 2. Press parent again within cycle window → cycle_press path
    _publish(client, TAP_SOURCE, "press_1")
    time.sleep(0.15)
    # 3. Press child → should still toggle off (cycle_press also
    #    re-marked child as physically on).
    _publish(client, TAP_SOURCE, "press_2")
    time.sleep(0.15)

    child_payloads = [json.loads(p) for p in inbox.payloads_on(TAP_TARGET_A)]
    assert child_payloads == [{"state": "OFF"}], (
        f"after parent cycles, child press should still toggle off. "
        f"got: {child_payloads}"
    )
