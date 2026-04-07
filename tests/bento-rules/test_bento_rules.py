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
