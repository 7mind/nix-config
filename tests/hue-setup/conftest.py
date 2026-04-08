"""Fixtures for hue_setup.py end-to-end tests.

These tests run the real `hue_setup` module against:
  * a real mosquitto broker on an ephemeral port (`mosquitto` fixture)
  * a fake zigbee2mqtt bridge that handles `bridge/request/*` topics
    in-process (`fake_z2m` fixture)

Nothing is mocked at the MQTT layer — paho-mqtt talks to a real broker
talking to a real (in-process) handler. The handler maintains a tiny
inventory of groups, members, and scenes, mirroring the parts of z2m's
behavior that hue_setup actually relies on.
"""

from __future__ import annotations

import contextlib
import json
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from threading import Event, Lock
from typing import Any, Iterator

import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion
import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
HUE_SETUP_DIR = REPO_ROOT / "pkg/hue-setup"

# Make `import hue_setup` work without relying on the wrapped binary.
# The directory is a hyphenated path so we cannot do a normal package
# import — we add it to sys.path and import the bare module.
sys.path.insert(0, str(HUE_SETUP_DIR))


# ---------- mosquitto (copy of bento-rules conftest, kept independent
# so the two test directories don't depend on each other) ----------


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_for_tcp(host: str, port: int, timeout_s: float = 5.0) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.2):
                return
        except (ConnectionRefusedError, OSError):
            time.sleep(0.05)
    raise TimeoutError(f"nothing listening on {host}:{port} after {timeout_s}s")


@pytest.fixture
def mosquitto() -> Iterator[tuple[str, int]]:
    host = "127.0.0.1"
    port = _free_port()
    with tempfile.TemporaryDirectory() as tmpdir:
        conf = Path(tmpdir) / "mosquitto.conf"
        conf.write_text(
            f"listener {port} {host}\n"
            "allow_anonymous true\n"
            "persistence false\n"
            "log_type none\n"
            "log_dest none\n"
        )
        proc = subprocess.Popen(
            ["mosquitto", "-c", str(conf)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            _wait_for_tcp(host, port)
            yield (host, port)
        finally:
            proc.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                proc.wait(timeout=5)
            if proc.poll() is None:
                proc.kill()


# ---------- fake zigbee2mqtt bridge ----------


class FakeZ2m:
    """Minimal in-memory zigbee2mqtt simulator.

    Handles only what hue_setup talks to:
      * `bridge/request/group/add`
      * `bridge/request/group/remove`
      * `bridge/request/group/members/add`
      * `bridge/request/group/members/remove`
      * `zigbee2mqtt/<group_or_device>/set` (scene_add and option writes)

    Republishes `bridge/groups` (retained) whenever inventory changes,
    so a `hue_setup.Z2mClient.fetch_groups` call sees a fresh snapshot
    after each mutation.
    """

    def __init__(self, host: str, port: int) -> None:
        self._lock = Lock()
        self._groups: dict[str, dict[str, Any]] = {}
        # Optional ghost ids: ids that are present in z2m's
        # settings.groups but missing from bridge/groups, simulating
        # the half-broken state we wrote prune handling for. While
        # an id is in _ghost_ids, `add_group` rejects with "already
        # in use"; a `remove_group` request that targets the numeric
        # id clears the ghost so a subsequent add succeeds.
        self._ghost_ids: set[int] = set()
        # Devices keyed by ieee_address. Each value mirrors the
        # subset of `bridge/devices` that hue_setup.fetch_devices
        # consumes (ieee_address, friendly_name, type).
        self._devices: dict[str, dict[str, Any]] = {}
        # Captured device-set publishes for assertions
        self.device_sets: list[tuple[str, dict[str, Any]]] = []
        # Captured raw scene_add JSON strings (so tests can verify
        # transition is encoded as a float, not an int)
        self.scene_add_raw: list[str] = []
        # Captured rename calls (ieee, from, to) for assertions on
        # the rename phase.
        self.rename_calls: list[tuple[str, str, str]] = []
        # Pre-seeded retained device states for option dedup tests:
        # tests put values here, the bridge republishes them as
        # retained on subscribe via mosquitto.
        self.device_state: dict[str, dict[str, Any]] = {}

        # Connection-ready barrier. on_connect sets the event after
        # the subscribes + initial retained publishes are queued, so
        # tests that race against the bridge subscribe wait here
        # rather than busy-polling a flag.
        self._subscribed_event = Event()

        self._client = mqtt.Client(
            CallbackAPIVersion.VERSION2,
            client_id="fake-z2m-bridge",
        )
        self._client.on_connect = self._on_connect
        self._client.on_message = self._on_message
        # connect_async + loop_start is more reliable under heavy
        # parallelism than the sync connect path: the network thread
        # owns both the TCP handshake and the CONNACK read, so we
        # can't get into a state where the main thread completed
        # connect() but the loop thread is starved before delivering
        # the callback.
        self._client.connect_async(host, port)
        self._client.loop_start()
        if not self._subscribed_event.wait(timeout=30.0):
            raise TimeoutError("fake z2m bridge failed to subscribe in time")

    def _on_connect(
        self,
        client: mqtt.Client,
        _userdata: Any,
        _flags: Any,
        _reason_code: Any,
        _properties: Any,
    ) -> None:
        client.subscribe("zigbee2mqtt/bridge/request/#", qos=1)
        client.subscribe("zigbee2mqtt/+/set", qos=1)
        # Publish initial (empty) inventory and any pre-seeded device
        # state retained, so subsequent re-subscribes from hue_setup
        # see the snapshot.
        self._publish_groups_locked_unsafe()
        self._publish_devices_locked_unsafe()
        for name, state in self.device_state.items():
            client.publish(
                f"zigbee2mqtt/{name}",
                json.dumps(state),
                qos=1,
                retain=True,
            )
        self._subscribed_event.set()

    # ---- inventory mutation helpers (must be called under self._lock) ----

    def _publish_groups_locked_unsafe(self) -> None:
        snapshot = list(self._groups.values())
        self._client.publish(
            "zigbee2mqtt/bridge/groups",
            json.dumps(snapshot),
            qos=1,
            retain=True,
        )

    def _publish_devices_locked_unsafe(self) -> None:
        snapshot = list(self._devices.values())
        self._client.publish(
            "zigbee2mqtt/bridge/devices",
            json.dumps(snapshot),
            qos=1,
            retain=True,
        )

    def _respond(
        self,
        request_topic: str,
        request_payload: dict[str, Any],
        *,
        status: str = "ok",
        data: Any = None,
        error: str | None = None,
    ) -> None:
        # bridge/request/group/add -> bridge/response/group/add
        action = request_topic.removeprefix("zigbee2mqtt/bridge/request/")
        response_topic = f"zigbee2mqtt/bridge/response/{action}"
        body: dict[str, Any] = {
            "status": status,
            "data": data if data is not None else {},
        }
        if "transaction" in request_payload:
            body["transaction"] = request_payload["transaction"]
        if error is not None:
            body["error"] = error
        self._client.publish(response_topic, json.dumps(body), qos=1)

    # ---- request handlers ----

    def _handle_group_add(self, payload: dict[str, Any]) -> None:
        friendly_name = payload["friendly_name"]
        # z2m sends id as a string in the request body
        raw_id = payload.get("id")
        group_id = int(raw_id) if raw_id is not None else self._next_auto_id()

        with self._lock:
            if group_id in self._ghost_ids:
                self._respond(
                    "zigbee2mqtt/bridge/request/group/add",
                    payload,
                    status="error",
                    error=f"group id {group_id} already in use",
                )
                return
            if friendly_name in self._groups:
                self._respond(
                    "zigbee2mqtt/bridge/request/group/add",
                    payload,
                    status="error",
                    error=f"group {friendly_name} already exists",
                )
                return
            self._groups[friendly_name] = {
                "id": group_id,
                "friendly_name": friendly_name,
                "members": [],
                "scenes": [],
            }
            self._publish_groups_locked_unsafe()
        self._respond(
            "zigbee2mqtt/bridge/request/group/add",
            payload,
            data={"friendly_name": friendly_name, "id": group_id},
        )

    def _handle_group_remove(self, payload: dict[str, Any]) -> None:
        target = payload["id"]  # may be friendly_name or numeric-id-as-string
        with self._lock:
            removed_friendly: str | None = None
            # Match by friendly name first
            if target in self._groups:
                removed_friendly = target
            else:
                # Otherwise treat target as a numeric id
                try:
                    target_id = int(target)
                except ValueError:
                    target_id = None
                if target_id is not None:
                    if target_id in self._ghost_ids:
                        # Clear the ghost so subsequent add succeeds
                        self._ghost_ids.discard(target_id)
                        self._respond(
                            "zigbee2mqtt/bridge/request/group/remove",
                            payload,
                            data={"id": target},
                        )
                        return
                    for name, group in list(self._groups.items()):
                        if group["id"] == target_id:
                            removed_friendly = name
                            break
            if removed_friendly is None:
                self._respond(
                    "zigbee2mqtt/bridge/request/group/remove",
                    payload,
                    status="error",
                    error=f"group {target} does not exist",
                )
                return
            del self._groups[removed_friendly]
            self._publish_groups_locked_unsafe()
        self._respond(
            "zigbee2mqtt/bridge/request/group/remove",
            payload,
            data={"id": target},
        )

    def _handle_members_add(self, payload: dict[str, Any]) -> None:
        group_name = payload["group"]
        device = payload["device"]
        endpoint = int(payload["endpoint"])
        with self._lock:
            group = self._groups.get(group_name)
            if group is None:
                self._respond(
                    "zigbee2mqtt/bridge/request/group/members/add",
                    payload,
                    status="error",
                    error=f"group {group_name} does not exist",
                )
                return
            entry = {"ieee_address": device, "endpoint": endpoint}
            if entry not in group["members"]:
                group["members"].append(entry)
                self._publish_groups_locked_unsafe()
        self._respond(
            "zigbee2mqtt/bridge/request/group/members/add",
            payload,
            data={"group": group_name, "device": device, "endpoint": endpoint},
        )

    def _handle_members_remove(self, payload: dict[str, Any]) -> None:
        group_name = payload["group"]
        device = payload["device"]
        endpoint = int(payload["endpoint"])
        with self._lock:
            group = self._groups.get(group_name)
            if group is None:
                self._respond(
                    "zigbee2mqtt/bridge/request/group/members/remove",
                    payload,
                    status="error",
                    error=f"group {group_name} does not exist",
                )
                return
            entry = {"ieee_address": device, "endpoint": endpoint}
            if entry in group["members"]:
                group["members"].remove(entry)
                self._publish_groups_locked_unsafe()
        self._respond(
            "zigbee2mqtt/bridge/request/group/members/remove",
            payload,
            data={"group": group_name, "device": device, "endpoint": endpoint},
        )

    def _handle_scene_add(self, group_name: str, raw: str, payload: dict[str, Any]) -> None:
        scene = payload["scene_add"]
        with self._lock:
            self.scene_add_raw.append(raw)
            group = self._groups.get(group_name)
            if group is None:
                return
            existing = next(
                (s for s in group["scenes"] if s["id"] == scene["ID"]),
                None,
            )
            entry = {"id": scene["ID"], "name": scene["name"]}
            if existing is None:
                group["scenes"].append(entry)
            else:
                existing["name"] = scene["name"]
            self._publish_groups_locked_unsafe()

    def _handle_device_rename(self, payload: dict[str, Any]) -> None:
        """Handle `bridge/request/device/rename`.

        z2m accepts both ieee_address and current friendly_name in
        `from`; we support both. The rename mutates `_devices`
        in-place and republishes `bridge/devices` retained so a
        subsequent `fetch_devices` sees the new name.
        """
        from_value = payload["from"]
        to_value = payload["to"]
        with self._lock:
            target_ieee: str | None = None
            if from_value in self._devices:
                target_ieee = from_value
            else:
                for ieee, dev in self._devices.items():
                    if dev["friendly_name"] == from_value:
                        target_ieee = ieee
                        break
            if target_ieee is None:
                self._respond(
                    "zigbee2mqtt/bridge/request/device/rename",
                    payload,
                    status="error",
                    error=f"device {from_value} does not exist",
                )
                return
            previous_name = self._devices[target_ieee]["friendly_name"]
            self._devices[target_ieee]["friendly_name"] = to_value
            self.rename_calls.append((target_ieee, previous_name, to_value))
            self._publish_devices_locked_unsafe()
        self._respond(
            "zigbee2mqtt/bridge/request/device/rename",
            payload,
            data={
                "from": from_value,
                "to": to_value,
                "homeassistant_rename": payload.get("homeassistant_rename", False),
            },
        )

    def _next_auto_id(self) -> int:
        with self._lock:
            used = {g["id"] for g in self._groups.values()} | self._ghost_ids
        for candidate in range(1, 256):
            if candidate not in used:
                return candidate
        raise RuntimeError("no free auto-id")

    # ---- main message dispatch ----

    def _on_message(
        self,
        _client: mqtt.Client,
        _userdata: Any,
        message: mqtt.MQTTMessage,
    ) -> None:
        topic = message.topic
        try:
            raw = message.payload.decode()
        except UnicodeDecodeError:
            return
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            return
        if not isinstance(payload, dict):
            return

        if topic == "zigbee2mqtt/bridge/request/group/add":
            self._handle_group_add(payload)
        elif topic == "zigbee2mqtt/bridge/request/group/remove":
            self._handle_group_remove(payload)
        elif topic == "zigbee2mqtt/bridge/request/group/members/add":
            self._handle_members_add(payload)
        elif topic == "zigbee2mqtt/bridge/request/group/members/remove":
            self._handle_members_remove(payload)
        elif topic == "zigbee2mqtt/bridge/request/device/rename":
            self._handle_device_rename(payload)
        elif topic.startswith("zigbee2mqtt/") and topic.endswith("/set"):
            target = topic[len("zigbee2mqtt/") : -len("/set")]
            if "scene_add" in payload:
                self._handle_scene_add(target, raw, payload)
            else:
                with self._lock:
                    self.device_sets.append((target, payload))

    # ---- public API for tests ----

    def add_existing_group(
        self,
        friendly_name: str,
        group_id: int,
        members: list[tuple[str, int]] | None = None,
        scenes: list[tuple[int, str]] | None = None,
    ) -> None:
        with self._lock:
            self._groups[friendly_name] = {
                "id": group_id,
                "friendly_name": friendly_name,
                "members": [
                    {"ieee_address": dev, "endpoint": ep}
                    for dev, ep in (members or [])
                ],
                "scenes": [
                    {"id": sid, "name": sname} for sid, sname in (scenes or [])
                ],
            }
            self._publish_groups_locked_unsafe()

    def add_existing_device(
        self,
        ieee_address: str,
        friendly_name: str,
        device_type: str = "Router",
    ) -> None:
        """Seed a device into the fake bridge's `bridge/devices`
        inventory. Used by rename-phase tests to model the live z2m
        state the reconciler observes."""
        with self._lock:
            self._devices[ieee_address] = {
                "ieee_address": ieee_address,
                "friendly_name": friendly_name,
                "type": device_type,
            }
            self._publish_devices_locked_unsafe()

    def device_snapshot(self) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(d) for d in self._devices.values()]

    def add_ghost_id(self, group_id: int) -> None:
        """Mark a group id as occupied in z2m's settings without
        having a corresponding entry in `bridge/groups`. While in
        this state, `add_group` for the id rejects with an error;
        `remove_group` against the numeric id clears the ghost."""
        with self._lock:
            self._ghost_ids.add(group_id)

    def seed_device_state(self, friendly_name: str, state: dict[str, Any]) -> None:
        """Pre-seed retained device state. Must be called BEFORE the
        fake bridge is created (because we publish at connect-time)
        OR via direct publish below."""
        self.device_state[friendly_name] = state
        # Also publish live so post-init seeding works
        self._client.publish(
            f"zigbee2mqtt/{friendly_name}",
            json.dumps(state),
            qos=1,
            retain=True,
        )

    def snapshot(self) -> list[dict[str, Any]]:
        with self._lock:
            return [
                {
                    "id": g["id"],
                    "friendly_name": g["friendly_name"],
                    "members": list(g["members"]),
                    "scenes": list(g["scenes"]),
                }
                for g in self._groups.values()
            ]

    def close(self) -> None:
        self._client.loop_stop()
        self._client.disconnect()


@pytest.fixture
def fake_z2m(mosquitto: tuple[str, int]) -> Iterator[FakeZ2m]:
    host, port = mosquitto
    bridge = FakeZ2m(host, port)
    try:
        yield bridge
    finally:
        bridge.close()
