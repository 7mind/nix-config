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
import time

import paho.mqtt.client as mqtt

from conftest import BentoRunner, MqttInbox


SOURCE_TOPIC = "test/switch/action"
MOTION_TOPIC = "test/motion-sensor"
TARGET_TOPIC = "test/group/set"


# ---------- config builders ----------


def _flat_cycle_config(*, debounce_ms: int, values: list[dict]) -> str:
    """Bento config for a flat cycle handler.

    Mirrors `mkSwitchRule` with a flat `values = [...]` cycle and the
    given debounce window. Presses on `{SOURCE_TOPIC}`, publishes to
    `{TARGET_TOPIC}`, state in an in-memory cache.
    """
    values_json = json.dumps(values)
    return f"""
http:
  enabled: false

cache_resources:
  - label: state
    memory: {{}}

input:
  mqtt:
    urls: ["tcp://{{MQTT_HOST}}:{{MQTT_PORT}}"]
    topics: ["{SOURCE_TOPIC}"]
    client_id: test-bento-cycle-in

pipeline:
  processors:
    - switch:
      - check: content().string() == "off_press_release"
        processors:
          - mapping: 'root = {{"state":"OFF"}}'
          - cache:
              resource: state
              operator: set
              key: preset_idx
              value: "0"
          - cache:
              resource: state
              operator: set
              key: preset_idx_last_ms
              value: "0"
      - check: content().string() == "on_press_release"
        processors:
          - branch:
              request_map: 'root = ""'
              processors:
                - cache:
                    resource: state
                    operator: get
                    key: preset_idx_last_ms
                - catch:
                  - mapping: 'root = "0"'
              result_map: 'meta preset_idx_last_ms = content().string()'
          - mapping: |
              let last = (meta("preset_idx_last_ms").or("0")).number().or(0)
              let now = timestamp_unix_milli()
              meta preset_idx_now_ms = $now.string()
              if ($now - $last) < {debounce_ms} {{ root = deleted() }}
          - cache:
              resource: state
              operator: set
              key: preset_idx_last_ms
              value: ${{! meta("preset_idx_now_ms") }}
          - branch:
              request_map: 'root = ""'
              processors:
                - cache:
                    resource: state
                    operator: get
                    key: preset_idx
                - catch:
                  - mapping: 'root = "0"'
              result_map: 'meta preset_idx_cur = content().string()'
          - mapping: |
              let cur = (meta("preset_idx_cur").or("0")).number().or(0)
              let next = ($cur + 1) % {len(values)}
              let presets = {values_json}
              meta preset_idx_next = $next.string()
              root = $presets.index($cur)
          - cache:
              resource: state
              operator: set
              key: preset_idx
              value: ${{! meta("preset_idx_next") }}
      - processors:
        - mapping: 'root = deleted()'

output:
  mqtt:
    urls: ["tcp://{{MQTT_HOST}}:{{MQTT_PORT}}"]
    topic: "{TARGET_TOPIC}"
    client_id: test-bento-cycle-out
"""


def _motion_config(*, max_illuminance: int) -> str:
    """Bento config for a motion sensor with luminance gate and a
    matching switch with lights_state coordination.

    Subscribes to both the motion sensor's JSON state topic and the
    switch's action topic. Both paths share `cache_resources.state`.
    """
    return f"""
http:
  enabled: false

cache_resources:
  - label: state
    memory: {{}}

input:
  broker:
    inputs:
      - mqtt:
          urls: ["tcp://{{MQTT_HOST}}:{{MQTT_PORT}}"]
          topics: ["{MOTION_TOPIC}"]
          client_id: test-bento-motion-in
      - mqtt:
          urls: ["tcp://{{MQTT_HOST}}:{{MQTT_PORT}}"]
          topics: ["{SOURCE_TOPIC}"]
          client_id: test-bento-switch-in

pipeline:
  processors:
    - switch:
      # Motion sensor source (JSON-format)
      - check: meta("mqtt_topic") == "{MOTION_TOPIC}"
        processors:
          - mapping: 'root = content().parse_json()'
          - mapping: 'meta out_topic = "{TARGET_TOPIC}"'
          - branch:
              request_map: 'root = ""'
              processors:
                - cache:
                    resource: state
                    operator: get
                    key: lights_state
                - catch:
                  - mapping: 'root = ""'
              result_map: 'meta lights_state = content().string()'
          - switch:
            - check: 'this.occupancy == true && (this.illuminance.or(99999).number()) < {max_illuminance} && (meta("lights_state").or("")) == ""'
              processors:
                - mapping: 'root = {{"scene_recall": 1}}'
                - cache:
                    resource: state
                    operator: set
                    key: lights_state
                    value: "motion"
            - check: 'this.occupancy == false && (meta("lights_state").or("")) == "motion"'
              processors:
                - mapping: 'root = {{"state":"OFF"}}'
                - cache:
                    resource: state
                    operator: set
                    key: lights_state
                    value: ""
            - processors:
              - mapping: 'root = deleted()'
      # Switch source (action-format)
      - check: meta("mqtt_topic") == "{SOURCE_TOPIC}"
        processors:
          - mapping: 'meta out_topic = "{TARGET_TOPIC}"'
          - switch:
            - check: content().string() == "off_press_release"
              processors:
                - mapping: 'root = {{"state":"OFF"}}'
                - cache:
                    resource: state
                    operator: set
                    key: lights_state
                    value: ""
            - check: content().string() == "on_press_release"
              processors:
                - mapping: 'root = {{"scene_recall": 1}}'
                - cache:
                    resource: state
                    operator: set
                    key: lights_state
                    value: "user"
            - check: content().string() == "up_press_release"
              processors:
                - mapping: 'root = {{"brightness_step": 25}}'
                - cache:
                    resource: state
                    operator: set
                    key: lights_state
                    value: "user"
            - processors:
              - mapping: 'root = deleted()'
      - processors:
        - mapping: 'root = deleted()'

output:
  mqtt:
    urls: ["tcp://{{MQTT_HOST}}:{{MQTT_PORT}}"]
    topic: ${{! meta("out_topic") }}
    client_id: test-bento-out
"""


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
