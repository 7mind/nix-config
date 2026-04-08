"""Tests for `pkg/zigbee-mqtt-import/zigbee_mqtt_import.py`.

Each test boots a real mosquitto, drops a retained `bridge/devices`
payload via `publish_bridge_devices`, then runs the importer against
the same broker and asserts on the JSON it prints.
"""

from __future__ import annotations

import io
import json
from contextlib import redirect_stdout

import pytest

import zigbee_mqtt_import  # type: ignore[import-not-found]
from conftest import publish_bridge_devices


# ---------- helpers ----------


def _client(mosquitto: tuple[str, int]) -> zigbee_mqtt_import.Z2mDevicesClient:
    host, port = mosquitto
    return zigbee_mqtt_import.Z2mDevicesClient(
        host=host,
        port=port,
        user="anything",
        password="anything",
        timeout_s=3.0,
    )


# ---------- build_mapping unit-level checks ----------


def test_build_mapping_extracts_typed_entries_keyed_by_ieee() -> None:
    """The output is `{ieee: {type, name}}`. With no `definition.exposes`
    on the input, type defaults to `unknown` — the test asserts the
    shape, not type inference (which has its own tests below)."""
    devices = [
        {"ieee_address": "0xaaaa", "friendly_name": "lamp-a", "type": "Router"},
        {"ieee_address": "0xbbbb", "friendly_name": "lamp-b", "type": "EndDevice"},
    ]
    assert zigbee_mqtt_import.build_mapping(devices) == {
        "0xaaaa": {"type": "unknown", "name": "lamp-a"},
        "0xbbbb": {"type": "unknown", "name": "lamp-b"},
    }


def test_build_mapping_skips_coordinator() -> None:
    """The coordinator is z2m's own bridge endpoint, not a real device,
    and including it would force every consumer to filter the literal
    string "Coordinator" out of its address space."""
    devices = [
        {"ieee_address": "0x0000", "friendly_name": "Coordinator", "type": "Coordinator"},
        {"ieee_address": "0xaaaa", "friendly_name": "lamp-a", "type": "Router"},
    ]
    assert zigbee_mqtt_import.build_mapping(devices) == {
        "0xaaaa": {"type": "unknown", "name": "lamp-a"},
    }


def test_build_mapping_skips_entries_with_missing_fields() -> None:
    """Real-world bridge/devices payloads sometimes contain stub
    entries (e.g. recently joined devices that haven't fully been
    interviewed yet). They should be ignored, not crash the import."""
    devices = [
        {"ieee_address": "0xaaaa", "friendly_name": "lamp-a"},
        {"ieee_address": "0xbbbb"},  # no friendly_name
        {"friendly_name": "lamp-c"},  # no ieee_address
        {},
    ]
    assert zigbee_mqtt_import.build_mapping(devices) == {
        "0xaaaa": {"type": "unknown", "name": "lamp-a"},
    }


def test_build_mapping_sorts_by_ieee_address() -> None:
    """Output must be stable across runs so the JSON can be checked
    into source control without churn from z2m's nondeterministic
    enumeration order. Sort key is the ieee, since that's the new
    catalog key."""
    devices = [
        {"ieee_address": "0x33", "friendly_name": "z-lamp"},
        {"ieee_address": "0x11", "friendly_name": "a-lamp"},
        {"ieee_address": "0x22", "friendly_name": "m-lamp"},
    ]
    mapping = zigbee_mqtt_import.build_mapping(devices)
    assert list(mapping.keys()) == ["0x11", "0x22", "0x33"]


def test_build_mapping_rejects_duplicate_friendly_name() -> None:
    """z2m enforces friendly_name uniqueness, so a duplicate is a
    corruption signal — surface it loudly rather than silently
    dropping a bulb on the floor."""
    devices = [
        {"ieee_address": "0xaaaa", "friendly_name": "lamp"},
        {"ieee_address": "0xbbbb", "friendly_name": "lamp"},
    ]
    with pytest.raises(ValueError, match="duplicate friendly_name"):
        zigbee_mqtt_import.build_mapping(devices)


# ---------- type inference ----------


def _device_with_exposes(exposes: list[dict]) -> dict:
    """Helper: build a minimal device dict with the given exposes."""
    return {
        "ieee_address": "0xtest",
        "friendly_name": "test-device",
        "type": "Router",
        "definition": {"exposes": exposes},
    }


def test_infer_type_light_from_top_level_exposure() -> None:
    """A Hue bulb's exposes contain a top-level entry with `type:
    "light"` (with sub-features for state, brightness, color_temp).
    The type-inference walker recognizes the top-level marker."""
    device = _device_with_exposes([
        {"type": "light", "features": [
            {"type": "binary", "name": "state"},
            {"type": "numeric", "name": "brightness"},
        ]},
    ])
    assert zigbee_mqtt_import.infer_device_type(device) == "light"


def test_infer_type_motion_sensor_from_occupancy_feature() -> None:
    """Hue motion sensors expose an `occupancy` binary feature
    (alongside illuminance, temperature, etc.)."""
    device = _device_with_exposes([
        {"type": "binary", "name": "occupancy"},
        {"type": "numeric", "name": "illuminance"},
    ])
    assert zigbee_mqtt_import.infer_device_type(device) == "motion-sensor"


def test_infer_type_tap_from_press_n_action_values() -> None:
    """The original Hue Tap (energy-harvesting ZGPSWITCH) exposes an
    `action` enum with values `press_1`, `press_2`, etc."""
    device = _device_with_exposes([
        {
            "type": "enum",
            "name": "action",
            "values": [
                "press_1", "press_2", "press_3", "press_4",
                "press_1_and_2", "release_1_and_2",
            ],
        },
    ])
    assert zigbee_mqtt_import.infer_device_type(device) == "tap"


def test_infer_type_switch_from_dimmer_action_values() -> None:
    """A Hue dimmer (RWL022 etc.) exposes an `action` enum with
    `on_press_release`, `up_press_release`, etc."""
    device = _device_with_exposes([
        {
            "type": "enum",
            "name": "action",
            "values": [
                "on_press_release", "off_press_release",
                "up_press_release", "down_press_release",
                "up_hold", "down_hold",
            ],
        },
    ])
    assert zigbee_mqtt_import.infer_device_type(device) == "switch"


def test_infer_type_walks_composite_features() -> None:
    """Some devices nest the relevant feature inside a composite —
    the walker must recurse into `features` lists, not just the top
    level. Without recursion, an `occupancy` buried inside a
    composite would be missed and the device classified as unknown."""
    device = _device_with_exposes([
        {
            "type": "composite",
            "name": "motion_sensor",
            "features": [
                {"type": "binary", "name": "occupancy"},
            ],
        },
    ])
    assert zigbee_mqtt_import.infer_device_type(device) == "motion-sensor"


def test_infer_type_unknown_when_no_signal_matches() -> None:
    """A device with exposes that don't match any of the inference
    patterns gets `unknown` — the user can correct it by hand."""
    device = _device_with_exposes([
        {"type": "numeric", "name": "battery"},
    ])
    assert zigbee_mqtt_import.infer_device_type(device) == "unknown"


def test_infer_type_unknown_when_no_definition() -> None:
    """A device entry without a `definition` block (a stub entry, or
    a coordinator-like row) defaults to unknown."""
    assert zigbee_mqtt_import.infer_device_type(
        {"ieee_address": "0x1", "friendly_name": "x"}
    ) == "unknown"


def test_infer_type_light_wins_over_other_signals() -> None:
    """If a device exposes both a light AND another signal (e.g. a
    hypothetical bulb with built-in motion), the more specific
    `light` classification wins."""
    device = _device_with_exposes([
        {"type": "light", "features": []},
        {"type": "binary", "name": "occupancy"},
    ])
    assert zigbee_mqtt_import.infer_device_type(device) == "light"


def test_build_mapping_threads_inferred_type_through() -> None:
    """End-to-end: a payload that exercises multiple inference
    branches gets the right type per device."""
    devices = [
        {
            "ieee_address": "0xaaaa", "friendly_name": "hue-l-foo",
            "definition": {"exposes": [{"type": "light"}]},
        },
        {
            "ieee_address": "0xbbbb", "friendly_name": "hue-s-bar",
            "definition": {"exposes": [
                {"type": "enum", "name": "action", "values": ["on_press_release"]}
            ]},
        },
        {
            "ieee_address": "0xcccc", "friendly_name": "hue-ts-baz",
            "definition": {"exposes": [
                {"type": "enum", "name": "action", "values": ["press_1", "press_2"]}
            ]},
        },
        {
            "ieee_address": "0xdddd", "friendly_name": "hue-ms-qux",
            "definition": {"exposes": [{"type": "binary", "name": "occupancy"}]},
        },
    ]
    assert zigbee_mqtt_import.build_mapping(devices) == {
        "0xaaaa": {"type": "light", "name": "hue-l-foo"},
        "0xbbbb": {"type": "switch", "name": "hue-s-bar"},
        "0xcccc": {"type": "tap", "name": "hue-ts-baz"},
        "0xdddd": {"type": "motion-sensor", "name": "hue-ms-qux"},
    }


# ---------- end-to-end via real mosquitto ----------


def test_fetch_devices_reads_retained_bridge_devices(
    mosquitto: tuple[str, int],
) -> None:
    publish_bridge_devices(
        *mosquitto,
        [
            {"ieee_address": "0xaaaa", "friendly_name": "lamp-a", "type": "Router"},
            {"ieee_address": "0xbbbb", "friendly_name": "lamp-b", "type": "EndDevice"},
        ],
    )
    client = _client(mosquitto)
    try:
        devices = client.fetch_devices()
    finally:
        client.close()
    assert {d["friendly_name"] for d in devices} == {"lamp-a", "lamp-b"}


def test_fetch_devices_times_out_when_nothing_published(
    mosquitto: tuple[str, int],
) -> None:
    """No retained payload exists yet — the importer must time out
    cleanly with a TimeoutError instead of hanging forever."""
    host, port = mosquitto
    client = zigbee_mqtt_import.Z2mDevicesClient(
        host=host,
        port=port,
        user="x",
        password="y",
        timeout_s=0.3,
    )
    try:
        with pytest.raises(TimeoutError):
            client.fetch_devices()
    finally:
        client.close()


def test_fetch_devices_rejects_non_list_payload(
    mosquitto: tuple[str, int],
) -> None:
    """If z2m ever publishes something other than a list (corruption,
    schema change), surface a clear error rather than producing
    nonsense output."""
    import paho.mqtt.client as mqtt
    from paho.mqtt.enums import CallbackAPIVersion

    host, port = mosquitto
    seeder = mqtt.Client(CallbackAPIVersion.VERSION2, client_id="bad-payload")
    seeder.connect(host, port)
    seeder.loop_start()
    info = seeder.publish(
        "zigbee2mqtt/bridge/devices",
        json.dumps({"unexpected": "object"}),
        qos=1,
        retain=True,
    )
    info.wait_for_publish(5.0)
    seeder.loop_stop()
    seeder.disconnect()

    client = _client(mosquitto)
    try:
        with pytest.raises(ValueError, match="unexpected payload shape"):
            client.fetch_devices()
    finally:
        client.close()


# ---------- top-level integration: fetch + build_mapping ----------


def test_end_to_end_produces_sorted_mapping(
    mosquitto: tuple[str, int],
) -> None:
    """Full pipeline: real mosquitto + real client + build_mapping.
    Verifies the same path the CLI runs in main(), minus the JSON
    serialization."""
    publish_bridge_devices(
        *mosquitto,
        [
            {"ieee_address": "0x0000", "friendly_name": "Coordinator", "type": "Coordinator"},
            {"ieee_address": "0xcccc", "friendly_name": "z-lamp", "type": "Router"},
            {"ieee_address": "0xaaaa", "friendly_name": "a-lamp", "type": "Router"},
            {"ieee_address": "0xbbbb", "friendly_name": "m-lamp", "type": "EndDevice"},
        ],
    )
    client = _client(mosquitto)
    try:
        devices = client.fetch_devices()
    finally:
        client.close()
    mapping = zigbee_mqtt_import.build_mapping(devices)
    # Sorted by ieee, with type defaulting to unknown (the test
    # devices don't carry a definition.exposes payload).
    assert list(mapping.items()) == [
        ("0xaaaa", {"type": "unknown", "name": "a-lamp"}),
        ("0xbbbb", {"type": "unknown", "name": "m-lamp"}),
        ("0xcccc", {"type": "unknown", "name": "z-lamp"}),
    ]
    # Stdout shape: pretty-printed JSON, terminating newline.
    buf = io.StringIO()
    with redirect_stdout(buf):
        json.dump(mapping, buf, indent=2, sort_keys=True)
        buf.write("\n")
    assert buf.getvalue().endswith("\n")
    parsed_back = json.loads(buf.getvalue())
    assert parsed_back == mapping
