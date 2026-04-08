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


def test_build_mapping_extracts_friendly_names_and_addresses() -> None:
    devices = [
        {"ieee_address": "0xaaaa", "friendly_name": "lamp-a", "type": "Router"},
        {"ieee_address": "0xbbbb", "friendly_name": "lamp-b", "type": "EndDevice"},
    ]
    assert zigbee_mqtt_import.build_mapping(devices) == {
        "lamp-a": "0xaaaa",
        "lamp-b": "0xbbbb",
    }


def test_build_mapping_skips_coordinator() -> None:
    """The coordinator is z2m's own bridge endpoint, not a real device,
    and including it would force every consumer to filter the literal
    string "Coordinator" out of its address space."""
    devices = [
        {"ieee_address": "0x0000", "friendly_name": "Coordinator", "type": "Coordinator"},
        {"ieee_address": "0xaaaa", "friendly_name": "lamp-a", "type": "Router"},
    ]
    assert zigbee_mqtt_import.build_mapping(devices) == {"lamp-a": "0xaaaa"}


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
    assert zigbee_mqtt_import.build_mapping(devices) == {"lamp-a": "0xaaaa"}


def test_build_mapping_sorts_by_friendly_name() -> None:
    """Output must be stable across runs so the JSON can be checked
    into source control without churn from z2m's nondeterministic
    enumeration order."""
    devices = [
        {"ieee_address": "0x33", "friendly_name": "z-lamp"},
        {"ieee_address": "0x11", "friendly_name": "a-lamp"},
        {"ieee_address": "0x22", "friendly_name": "m-lamp"},
    ]
    mapping = zigbee_mqtt_import.build_mapping(devices)
    assert list(mapping.keys()) == ["a-lamp", "m-lamp", "z-lamp"]


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
    assert list(mapping.items()) == [
        ("a-lamp", "0xaaaa"),
        ("m-lamp", "0xbbbb"),
        ("z-lamp", "0xcccc"),
    ]
    # Stdout shape: pretty-printed JSON, terminating newline.
    buf = io.StringIO()
    with redirect_stdout(buf):
        json.dump(mapping, buf, indent=2, sort_keys=True)
        buf.write("\n")
    assert buf.getvalue().endswith("\n")
    parsed_back = json.loads(buf.getvalue())
    assert parsed_back == mapping
